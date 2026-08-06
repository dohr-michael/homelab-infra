# Ajouter un nœud k3s server au cluster

Procédure pour ajouter un nœud **server** (control-plane + etcd), pas un agent :
c'est le rôle server qui fait grossir le quorum etcd.

> **Appliquée avec succès le 2026-08-06** pour `vps-4541d883` (100.64.0.11,
> 4 vCPU / 8 Go, Ubuntu 24.04.4, k3s v1.34.3+k3s1). etcd est passé de 2 à 3 membres.
> Le nœud a reçu exactement l'IP prévue par l'allocation séquentielle de Headscale, et
> a rejoint sans taint, comme voulu.
>
> Un seul défaut relevé après coup : dans la version initiale du script, deux
> commentaires du `config.yaml` généré avaient perdu des mots. Cause — les backticks
> dans un heredoc **non quoté** sont exécutés comme substitution de commande. Corrigé,
> avec un garde en commentaire pour ne pas le réintroduire.

Le gros du travail est fait par `infra/new-node-bootstrap.sh`. Ce document explique
ce qu'il fait, pourquoi, et les deux ou trois choses qu'il ne peut pas faire.

---

## 1. Configuration existante, relevée le 2026-08-06

Inventaire fait sur `vps-a7c3e9b8` (`ubuntu@`, sudo sans mot de passe).

**k3s v1.34.3+k3s1.** Aucun `/etc/rancher/k3s/config.yaml` : toute la configuration
est en flags dans l'unit systemd.

```
/usr/local/bin/k3s server
    --cluster-init                            # ce nœud a initialisé le cluster etcd
    --node-ip=100.64.0.1                      # IP Headscale, pas l'IP publique
    --advertise-address=100.64.0.1
    --flannel-iface=tailscale0                # le réseau pod passe DANS le tunnel
    --tls-san=100.64.0.1
    --tls-san=vps-a7c3e9b8.home.dohrm.fr
```

**Headscale v0.28.0**, systemd sur ce même VPS, `listen_addr: 127.0.0.1:8080`,
`server_url: https://vpn.dohrm.fr:443` (Caddy devant). Points qui comptent :

- `prefixes.allocation: sequential` → les IP sont attribuées dans l'ordre ; les nœuds
  vont de `100.64.0.1` à `100.64.0.10`, **le prochain sera `100.64.0.11`**. Le script
  ne le suppose pas pour autant : il lit l'IP réellement attribuée.
- `magic_dns: true`, `base_domain: home.dohrm.fr` → chaque nœud obtient
  `<hostname>.home.dohrm.fr`.
- `policy.mode: file` avec `path: ""` → **aucune ACL**. Tous les nœuds se joignent sur
  tous les ports, rien à autoriser pour le nouveau.

**Caddy** termine le TLS avec un wildcard `*.home.dohrm.fr` (DNS-01 OVH), refuse tout
ce qui ne vient pas de `100.64.0.0/16`, et proxy vers Traefik sur `localhost:81`.
Aucune modification nécessaire pour un nouveau nœud.

**ufw actif**, `INPUT DROP` par défaut. La règle qui fait tout fonctionner :

```
Anywhere on tailscale0     ALLOW       Anywhere
```

Tout le trafic cluster (6443, kubelet 10250, etcd 2379-2380, VXLAN flannel) passe par
là. **Rien n'est ouvert sur l'IP publique** en dehors de 80/443 pour Caddy.

---

## 2. Première connexion : préparer l'accès

OVH livre déjà l'utilisateur `ubuntu` (groupe `sudo`, `NOPASSWD` via
`/etc/sudoers.d/90-cloud-init-users`) avec **un mot de passe temporaire à changer**.
Il reste donc surtout à installer les clés SSH et à lever ce changement forcé.

### Le piège du mot de passe à reset

Tant que le changement est en attente, PAM le réclame **à chaque ouverture de
session, même par clé**. Tout SSH non interactif échoue : `ssh <hôte> 'cmd'`, `scp`,
et donc `new-node-bootstrap.sh`. C'est la première chose que le script contrôle, et il
s'arrête tant que ce n'est pas réglé.

Il ne change pas le mot de passe à ta place, volontairement : lever le drapeau sans le
changer laisserait actif celui fourni par OVH, arrivé par un canal que tu ne maîtrises
pas — et c'est la seule protection de la console de secours.

### Déroulé

```bash
# 1. Depuis ton poste : récupérer les clés déjà autorisées sur le cluster
ssh ubuntu@vps-a7c3e9b8 'sudo cat /home/ubuntu/.ssh/authorized_keys' > /tmp/ak
scp /tmp/ak infra/new-node-root-init.sh root@<nouveau-noeud>:/tmp/

# 2. En root sur le nouveau nœud
ssh root@<nouveau-noeud>

passwd ubuntu                       # définir un VRAI mot de passe (lève le drapeau)
/tmp/new-node-root-init.sh --keys /tmp/ak
```

Le script vérifie l'utilisateur, aligne l'expiration du mot de passe sur celle du nœud
de référence, pose une règle sudoers explicite (validée par `visudo -c` avant
installation — un sudoers cassé supprime *tout* accès sudo, y compris pour réparer), et
**fusionne** les clés sans écraser celles déjà présentes.

### Vérifier, puis durcir

Sans fermer la session root :

```bash
# depuis ton poste
ssh ubuntu@<nouveau-noeud> 'echo ok && sudo -n true && echo sudo-ok'
```

Les deux `ok` doivent s'afficher. Ensuite seulement :

```bash
/tmp/new-node-root-init.sh --harden
```

Ça écrit `/etc/ssh/sshd_config.d/10-homelab.conf` (préfixe `10-` volontaire) (`PasswordAuthentication no`,
`PermitRootLogin no`), valide avec `sshd -t`, puis fait un `reload` — pas un `restart`,
pour que la session en cours survive en cas de problème.

> **Le préfixe `10-` n'est pas arbitraire.** sshd retient la **première** valeur lue
> pour une directive. Relevé sur `vps-a7c3e9b8` : `50-cloud-init.conf` pose
> `PasswordAuthentication yes` et `60-cloudimg-settings.conf` pose `no` — le durcissement
> de l'image OVH est donc silencieusement annulé par cloud-init, et l'auth par mot de
> passe est **active** sur le nœud actuel. Un fichier en `70-` n'aurait servi à rien.
> Les nœuds existants mériteraient le même drop-in.

### Hostname — à fixer maintenant ou jamais

Le hostname devient le nom du nœud Kubernetes **et** son nom MagicDNS
(`<hostname>.home.dohrm.fr`). Le changer après l'installation de k3s créerait un second
objet `Node`. Si tu veux autre chose que le nom OVH par défaut :

```bash
hostnamectl set-hostname <nom> && reboot
```

---

## 3. Créer une clé d'enrôlement Headscale

Sur `vps-a7c3e9b8`. La syntaxe a changé en 0.28 : `-u` prend un **ID numérique**,
plus un nom d'utilisateur.

```bash
ssh ubuntu@vps-a7c3e9b8 'sudo headscale users list'          # michael = ID 1
ssh ubuntu@vps-a7c3e9b8 'sudo headscale preauthkeys create -u 1 -e 24h'
```

Clé à usage unique (pas de `--reusable`), valable 24 h : elle ne sert qu'une fois.

---

## 4. Récupérer le token k3s

```bash
ssh ubuntu@vps-a7c3e9b8 'sudo cat /var/lib/rancher/k3s/server/token'
```

> Ce token donne le contrôle total du cluster. Le passer par une variable
> d'environnement, ne pas le coller dans un fichier versionné, ne pas le laisser dans
> l'historique du shell (`export HISTCONTROL=ignorespace` puis préfixer d'un espace).

---

## 5. Lancer le bootstrap sur le nouveau nœud

```bash
scp infra/new-node-bootstrap.sh ubuntu@<nouveau-noeud>:/tmp/
ssh ubuntu@<nouveau-noeud>

# Vérifie les prérequis sans rien modifier
sudo /tmp/new-node-bootstrap.sh --check

 export HEADSCALE_AUTHKEY='...'      # espace initial volontaire : pas d'historique
 export K3S_TOKEN='...'
sudo -E /tmp/new-node-bootstrap.sh
```

Ce que le script enchaîne, dans cet ordre — **l'ordre est contraint** :

1. contrôles (RAM ≥ 4 Go, ≥ 30 Go libres sur `/`)
2. client tailscale, enrôlement sur `https://vpn.dohrm.fr`, **attente de l'IP**
3. ufw : `allow in on tailscale0` + SSH depuis le tailnet uniquement
4. drop-in systemd `After=tailscaled.service` (voir §6)
5. `/etc/rancher/k3s/config.yaml` avec l'IP Headscale réellement attribuée
6. installation de k3s en `server`, sans `--cluster-init`

Headscale doit être joint **avant** k3s, puisque k3s se configure avec l'IP du tunnel
et démarre flannel sur `tailscale0`.

Le script est idempotent : relançable sans casse.

---

## 6. Écarts assumés par rapport aux nœuds existants

Trois différences volontaires, chacune parce que reproduire l'existant serait
reproduire un défaut.

| Écart | Pourquoi |
|---|---|
| Config dans `/etc/rancher/k3s/config.yaml`, pas en flags dans l'unit | Relisible, modifiable sans toucher à l'unit, et survit à une réinstallation de k3s. Les nœuds existants gagneraient à être alignés, mais ça demande un redémarrage de l'API server : à faire à froid, pas maintenant. |
| Drop-in `After=tailscaled.service` | Les unit k3s existantes ne déclarent que `After=network-online.target` alors que k3s tourne avec `--flannel-iface=tailscale0`. Si tailscaled démarre après k3s, k3s échoue. Ça n'a pas encore mordu, mais c'est une fragilité au boot. |
| `--tls-san=k8s.home.dohrm.fr` ajouté d'avance | Le jour où le load-balancer d'API arrive, il faudra ce SAN sur **tous** les API servers. L'ajouter maintenant coûte zéro ; l'ajouter plus tard impose un redémarrage roulant des trois. |
| Pas de taint `CriticalAddonsOnly` | `vps-17435151` en porte un, ce qui explique que rien ne s'y schedule et que presque tout tourne sur `vps-a7c3e9b8`. On ne veut pas d'un troisième nœud inutilisable : il doit accueillir un membre MongoDB. |

En revanche, un point où le script **s'aligne délibérément sur l'existant plutôt que de
corriger** : le DNS. Relevé sur `vps-a7c3e9b8` :

```
Link 3 (tailscale0)
       DNS Servers: 100.100.100.100
        DNS Domain: home.dohrm.fr ~.
```

Le `~.` signifie que **toute** la résolution DNS du nœud passe par Headscale, et comme
CoreDNS fait `forward . /etc/resolv.conf`, la résolution externe des pods en dépend
aussi. Si `tailscaled` tombe sur le nœud qui héberge CoreDNS, le DNS sortant des pods
tombe avec lui.

Corriger ça sur le seul nouveau nœud serait pire que de ne rien faire : CoreDNS n'a
qu'un replica, et le comportement DNS du cluster changerait selon le nœud où il
atterrit. C'est le genre d'incohérence qui coûte une demi-journée à diagnostiquer.
**À trancher pour les trois nœuds en même temps**, hors de cette procédure. L'option
serait `--accept-dns=false` partout, plus un `forward` explicite dans le Corefile.

---

## 7. Ce qui reste fragile — et qui n'est pas résolu par ce nœud

**Le join pointe sur une adresse fixe.** `server: https://100.64.0.1:6443` crée une
dépendance au démarrage envers `vps-a7c3e9b8`. Une fois le nœud membre du cluster
etcd, le fonctionnement courant n'en dépend plus, mais un **redémarrage** du nouveau
nœud pendant que `100.64.0.1` est down peut échouer. C'est précisément le rôle du
load-balancer d'API que tu as remis à plus tard. Deux atténuations d'ici là :

- viser `100.64.0.3` (`vps-17435151`) plutôt que `.1` depuis le nouveau nœud, pour ne
  pas concentrer les trois dépendances de démarrage sur le même hôte ;
- ou créer un record `k8s.home.dohrm.fr` dans `applications/headscale/10-dns-sync.yaml`
  et l'utiliser comme `server:` — le SAN est déjà prévu. Attention : un record A unique
  ne fait pas du round-robin utile ici, ça déplace le problème sans le résoudre.

**Caddy reste un point d'entrée unique** sur `100.64.0.1` : tous les records
`*.home.dohrm.fr` y pointent. Le nouveau nœud n'y change rien. Le vrai correctif est
un LB devant Caddy, ou Caddy sur plusieurs nœuds avec un record partagé.

**etcd à 3 membres tolère la perte d'UN nœud, pas deux.** Avec un membre par région
OVH, une panne de région = un membre. Correct, mais ça ne laisse aucune marge pour une
maintenance simultanée : ne jamais redémarrer deux serveurs en même temps.

---

## 8. Après le bootstrap

```bash
export KUBECONFIG=~/.kube/home.dohrm
kubectl get nodes -o wide                                    # 3 control-plane,etcd Ready
kubectl get nodes -l node-role.kubernetes.io/etcd=true        # doit renvoyer 3 lignes
```

Puis, dans l'ordre :

1. **Labels** — éditer `PROD_NODES` dans `infra/label-nodes.sh` (ajouter le nouveau nœud,
   retirer `gmk-ai-master`), commiter, puis rejouer le script. C'est la source de vérité
   du placement, elle ne doit pas diverger du cluster.
2. **Déplacer le membre MongoDB** — `docs/critical-app-readiness.md` §6, un changement à
   la fois.
3. **Snapshots etcd** — une fois le bucket OVH créé et `applications/cluster-baseline`
   déployé, passer `etcd-s3: true` dans `config.yaml` sur les **trois** nœuds, un par un
   (`systemctl restart k3s`), en vérifiant `kubectl get nodes` entre chaque.
4. Vérifier que l'alerte `EtcdQuorumFragile` s'est tue.

> Le §3 devient sûr **seulement maintenant** : avec 2 membres etcd, redémarrer un
> serveur cassait le quorum. À 3 membres, un redémarrage roulant est sans danger.
> C'est la raison pour laquelle l'ordre de ce document n'est pas indifférent.
