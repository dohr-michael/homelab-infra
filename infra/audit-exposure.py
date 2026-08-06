#!/usr/bin/env python3
"""
Audit d'exposition réseau des nœuds, depuis l'extérieur du VPN.

C'est l'outil qui a trouvé les deux failles du 2026-08-06 (API server sur
Internet, ServiceLB contournant ufw). Il doit donc rester rejouable — mais
prudemment.

À LANCER DEPUIS UNE MACHINE HORS TAILNET, ou au moins en visant les IP publiques
(le trafic vers une IP publique ne passe pas par le tunnel, même depuis un nœud
du tailnet, donc c'est un test externe valable).

--------------------------------------------------------------------- PRUDENCE
La première version balayait les 65535 ports des 3 nœuds avec 800 connexions
simultanées. Quelques minutes plus tard, `vps-4541d883` a perdu tout son trafic
ENTRANT : sortant OK, `rx 0` sur tous ses pairs, et même les réponses DNS de
1.1.1.1 perdues. Un reboot n'y a rien changé — signature d'un filtrage EN AMONT
de la VM, pas d'un problème sur la machine. La mitigation DDoS d'OVH prend un
balayage massif pour une attaque et filtre l'IP visée.

Note : la saturation de la table conntrack a été envisagée puis ÉCARTÉE.
`nf_conntrack_max` vaut 131072 sur ces nœuds (posé par kube-proxy d'après la
RAM) pour ~6000 entrées en usage courant ; le balayage en aurait ajouté 65535 au
plus, donc ~71k, sous la limite. Le pré-contrôle conntrack est conservé comme
simple vérification, pas comme cause identifiée.

D'où les garde-fous par défaut :
  - un seul nœud à la fois, jamais en parallèle
  - concurrence faible (8) et pause entre les lots — c'est le profil de trafic
    qui déclenche la détection, pas le nombre de ports en soi
  - la liste de ports « pertinents » suffit à répondre à la question posée
    (« quoi d'ouvert hors VPN ? ») ; le balayage complet demande --all et une
    confirmation explicite

Usage :
    ./infra/audit-exposure.py                 # ports pertinents (recommandé)
    ./infra/audit-exposure.py --all           # 65535 ports, lent et risqué
    ./infra/audit-exposure.py --host vps-a7c3e9b8
"""
import argparse
import socket
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

# Renseigné le 2026-08-06. `dig +short <host>.vps.ovh.net` pour vérifier.
NODES = {
    "vps-a7c3e9b8": ("51.178.19.49", "2001:41d0:305:2100::46c1", "100.64.0.1"),
    "vps-17435151": ("135.125.132.11", "2001:41d0:701:1100::8441", "100.64.0.3"),
    "vps-4541d883": ("164.132.187.206", "2001:41d0:20a:900::212e", "100.64.0.11"),
}

# Ce qu'on veut réellement savoir : les ports qui trahissent une exposition.
RELEVANT_PORTS = sorted({
    22,                       # SSH
    80, 443,                  # Caddy — légitime sur vps-a7c3e9b8
    2379, 2380,               # etcd client + peer
    6443,                     # apiserver k3s
    7000,                     # frps — légitime sur vps-a7c3e9b8
    8080, 8443,               # admin divers
    9100,                     # node-exporter
    10250, 10255, 10256,      # kubelet
    81, 444,                  # entrypoints Traefik derrière Caddy
    9000, 9001,               # RustFS
    27017,                    # MongoDB
    3000, 8428, 8880, 9093,   # Grafana, vmsingle, vmalert, Alertmanager
    *range(30000, 30010),     # début de la plage NodePort
    30594, 31767,             # NodePorts Traefik (historique)
})

# Ce qui est légitimement ouvert, pour ne pas crier au loup.
EXPECTED = {"vps-a7c3e9b8": {80, 443, 7000}}


def preflight(name):
    """Vérifie nf_conntrack sur le nœud si on peut l'atteindre en SSH."""
    ip_vpn = NODES[name][2]
    try:
        out = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", f"ubuntu@{ip_vpn}",
             "cat /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max"],
            capture_output=True, text=True, timeout=15)
        vals = out.stdout.split()
        if len(vals) == 2:
            count, mx = int(vals[0]), int(vals[1])
            print(f"    conntrack {count}/{mx}", end="")
            # Un balayage crée une entrée par port sondé. 131072 (valeur posée
            # par kube-proxy sur un nœud 8 Go) laisse de la marge pour 65535
            # sondes ; en dessous de 100k, la marge devient mince.
            if mx < 100000:
                print("  ⚠ marge mince pour un --all (65535 sondes)")
            else:
                print("  (marge suffisante)")
            return
    except Exception:
        pass
    print("    conntrack : non vérifiable (pas d'accès SSH) — prudence")


def scan(ip, family, ports, workers, pause):
    """Scan TCP connect, par lots, avec pause entre les lots."""
    found = []

    def probe(port):
        try:
            s = socket.socket(family, socket.SOCK_STREAM)
            s.settimeout(2.0)
            rc = s.connect_ex((ip, port))
            s.close()
            return port if rc == 0 else None
        except Exception:
            return None

    ports = list(ports)
    for i in range(0, len(ports), workers * 8):
        chunk = ports[i:i + workers * 8]
        with ThreadPoolExecutor(max_workers=workers) as ex:
            found += [p for p in ex.map(probe, chunk) if p]
        if pause and i + workers * 8 < len(ports):
            time.sleep(pause)
    return sorted(found)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--all", action="store_true",
                    help="balaye les 65535 ports (lent, peut déclencher la mitigation OVH)")
    ap.add_argument("--host", help="un seul nœud")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--pause", type=float, default=0.5,
                    help="pause entre les lots, en secondes")
    args = ap.parse_args()

    targets = {args.host: NODES[args.host]} if args.host else NODES
    if args.host and args.host not in NODES:
        sys.exit(f"nœud inconnu : {args.host}")

    ports = range(1, 65536) if args.all else RELEVANT_PORTS

    if args.all:
        print("⚠  Balayage complet des 65535 ports.")
        print("   Le 2026-08-06, un balayage massif et parallèle a fait filtrer")
        print("   l'IP d'un nœud par la mitigation OVH : le nœud a perdu tout son")
        print("   trafic entrant pendant ~1 h. Un nœud à la fois, sans hâte.")
        if input("   Continuer ? [oui/NON] ").strip().lower() not in ("oui", "o", "yes", "y"):
            sys.exit("annulé")

    print(f"\n{len(list(ports))} ports par cible, {args.workers} connexions simultanées, "
          f"pause {args.pause}s\n")

    problems = 0
    for name, (v4, v6, _) in targets.items():
        print(f"=== {name}")
        preflight(name)
        for label, ip, fam in (("IPv4", v4, socket.AF_INET), ("IPv6", v6, socket.AF_INET6)):
            open_ports = scan(ip, fam, ports, args.workers, args.pause)
            expected = EXPECTED.get(name, set())
            unexpected = [p for p in open_ports if p not in expected]
            verdict = "OK" if not unexpected else f"⚠ {len(unexpected)} port(s) inattendu(s)"
            print(f"    {label:4} {ip:32} ouverts={open_ports or 'aucun'}  {verdict}")
            if unexpected:
                problems += 1
                print(f"         inattendus : {unexpected}")
        print()

    if problems:
        print("Des ports inattendus sont joignables hors VPN. Voir")
        print("infra/fixes/README.md — en particulier le contournement d'ufw par ServiceLB.")
        return 1
    print("Aucun port inattendu joignable hors VPN.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
