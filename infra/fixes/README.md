# Audit d'exposition réseau du 2026-08-06 — ✅ corrigé

Compte rendu de l'audit et des correctifs, conservé comme trace. **Les deux
correctifs ont été appliqués et vérifiés le 2026-08-06.**

- Le correctif Traefik, une fois prouvé en production, a été déplacé sous GitOps :
  `applications/cluster-baseline/30-traefik-lb.yaml`.
- `ufw-baseline.sh` reste ici : c'est un script de nœud, pas un manifeste.

## Résultat final — scan TCP complet (65535 ports, IPv4 + IPv6), depuis Internet

| Nœud | avant | après |
|---|---|---|
| `vps-a7c3e9b8` | 80, 443, 7000, **81, 444, 30594, 31767** | 80, 443, 7000 |
| `vps-17435151` | **22, 81, 444, 6443, 10250, 30594, 31767** | *(aucun)* |
| `vps-4541d883` | **81, 444, 30594, 31767** | *(aucun)* |

Idem en IPv6 : plus rien d'ouvert hors 80/443/7000 sur `vps-a7c3e9b8`.

Services vérifiés intacts après correctifs : `n8n`=200, `argo`=200, `vpn`=302,
`tinypaw.fr`=200 (le site public passe toujours par Caddy → Traefik).

Une alerte `UnexpectedPubliclyExposedService` a été ajoutée pour détecter tout
futur Service NodePort/LoadBalancer, qui rouvrirait le trou silencieusement.

## Rejouer l'audit : `infra/audit-exposure.py`

Le scan initial était brutal — 65535 ports × 3 nœuds × 800 connexions
simultanées. Quelques minutes après, `vps-4541d883` a perdu **tout son trafic
entrant** : sortant OK, `rx 0` sur tous ses pairs Tailscale, réponses DNS de
1.1.1.1 perdues, et un reboot sans effet. Signature d'un filtrage **en amont de
la VM** : la mitigation DDoS d'OVH prend un balayage massif pour une attaque.

> La saturation de la table conntrack a été envisagée puis **écartée** :
> `nf_conntrack_max` vaut 131072 sur ces nœuds (posé par kube-proxy d'après la
> RAM) contre ~6000 entrées en usage courant. 65535 sondes de plus donnent ~71k,
> sous la limite. Ce n'était pas la cause.

`audit-exposure.py` remplace ce scan : un nœud à la fois, 8 connexions
simultanées, pause entre les lots, et par défaut une liste de ~34 ports
pertinents qui suffit à répondre à la question. Le balayage complet reste
possible via `--all`, derrière une confirmation.

```bash
./infra/audit-exposure.py                      # recommandé
./infra/audit-exposure.py --host vps-a7c3e9b8
```

Il connaît les ports légitimes (80, 443, 7000 sur `vps-a7c3e9b8`) et ne signale
que le reste. Code de sortie non nul s'il trouve quelque chose — utilisable
depuis l'audit IA périodique.

## Contexte : audit d'exposition du 2026-08-06

Scan TCP complet (65535 ports, IPv4 + IPv6) depuis l'extérieur du VPN, sur les
trois VPS OVH :

| Nœud | TCP public IPv4 | TCP public IPv6 |
|---|---|---|
| `vps-a7c3e9b8` | 80, 443, 7000, **81, 444, 30594, 31767** | 80, 443, 7000 |
| `vps-17435151` | **22, 6443, 10250**, **81, 444, 30594, 31767** | **22, 6443, 10250** |
| `vps-4541d883` | **81, 444, 30594, 31767** | *(aucun)* |

En gras : ce qui ne devrait pas être joignable hors Headscale.

Sur `vps-a7c3e9b8`, 80/443 (Caddy) et 7000 (frps) sont légitimes. Les ports de
jeux (7777, 25565, 27015…) n'apparaissent pas parce que frps ne les ouvre que
lorsqu'un client frpc est connecté.

### Constat 1 — `vps-17435151` n'a pas de pare-feu effectif

L'**API server Kubernetes (6443)**, le **kubelet (10250)** et **SSH (22)** sont
joignables depuis Internet, en IPv4 et IPv6. Vérifié :

```
$ curl -sk https://135.125.132.11:6443/version
{"kind":"Status","message":"Unauthorized","code":401}
$ openssl s_client -connect 135.125.132.11:6443 | openssl x509 -subject
subject=O=k3s, CN=k3s
```

Les deux répondent 401, donc pas exploitables sans identifiants — mais toute
CVE d'authentification sur `kube-apiserver` ou `kubelet` deviendrait
exploitable à distance, et une fuite de token donnerait le cluster entier.

Correctif : `ufw-baseline.sh`. C'est le point le plus grave, et il est
indépendant du constat 2.

### Constat 2 — ServiceLB contourne ufw sur les trois nœuds

`81`, `444`, `30594` et `31767` sont joignables publiquement sur les trois
nœuds, **alors qu'ufw contient des règles `DENY` explicites** pour 81 et 444
(règles 12 et 13 sur `vps-a7c3e9b8`).

Cause : le ServiceLB de k3s (`klipper-lb`) déploie un DaemonSet `svclb-traefik`
sur chaque nœud avec `hostPort: 81/444`. Le trafic est donc DNAT-é dans la table
`nat` (PREROUTING) puis traverse `FORWARD` — alors que les règles d'ufw
inspectées ici sont dans `INPUT`. Elles ne voient jamais ce trafic. Les chaînes
`KUBE-*` sont d'ailleurs branchées **avant** ufw dans `INPUT` :

```
1  -P INPUT DROP
2  -A INPUT -j KUBE-ROUTER-INPUT
...
7  -A INPUT -m mark --mark 0x20000/0x20000 -j ACCEPT
8  -A INPUT -j ufw-before-logging-input      <- ufw commence seulement ici
```

**Impact réel, mesuré** : joindre Traefik en direct contourne Caddy, donc
contourne le filtre `remote_ip 100.64.0.0/16` qui est la *seule* protection des
services internes.

```
$ curl -H 'Host: n8n.home.dohrm.fr'  http://51.178.19.49:81/   -> HTTP 200
$ curl -H 'Host: argo.home.dohrm.fr' http://51.178.19.49:81/   -> HTTP 200
$ curl -H 'Host: n8n.home.dohrm.fr'  http://51.178.19.49:30594/ -> HTTP 200
```

n8n et l'interface ArgoCD sont donc accessibles depuis Internet **aujourd'hui**.
Et au prochain déploiement, Grafana, Alertmanager, vmsingle, vmalert et RustFS
les rejoindraient — dont trois qui n'ont aucune authentification propre.

IPv6 est épargné : les règles de `klipper-lb` et de `kube-proxy` sont en
IPv4 seulement sur ce cluster single-stack.

Correctif : `traefik-lb-sourceranges.yaml`.
