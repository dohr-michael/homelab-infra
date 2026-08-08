#!/usr/bin/env bash
##############################################################################
# Bootstrap d'un nouveau nœud k3s server (control-plane + etcd)
#
# À exécuter SUR LE NOUVEAU NŒUD, en root ou avec sudo.
#
# Ce script reproduit exactement la configuration des nœuds existants, telle
# qu'inventoriée sur vps-a7c3e9b8 le 2026-08-06 :
#   - tout le trafic cluster passe par l'interface Headscale (`tailscale0`)
#   - `--node-ip` / `--advertise-address` portent l'IP Headscale, pas l'IP publique
#   - ufw autorise tout sur `tailscale0` : c'est CE qui laisse passer 6443,
#     10250, 2379-2380 et le VXLAN de flannel entre nœuds
#
# Ordre imposé, non négociable : Headscale DOIT être joint et l'IP attribuée
# AVANT d'installer k3s, puisque k3s se configure avec cette IP.
#
# Usage :
#   export HEADSCALE_AUTHKEY='...'     # cf. docs/add-k3s-node.md §3
#   export K3S_TOKEN='...'             # cf. docs/add-k3s-node.md §4
#   sudo -E ./new-node-bootstrap.sh              # exécution
#   sudo -E ./new-node-bootstrap.sh --check      # vérifie sans rien modifier
#
# Idempotent : relançable sans casse à n'importe quelle étape.
##############################################################################
set -euo pipefail

# ---------------------------------------------------------------- paramètres
HEADSCALE_URL="${HEADSCALE_URL:-https://vpn.dohrm.fr}"
# IP Headscale d'un serveur k3s existant, utilisée pour rejoindre le cluster.
# Pas de load-balancer devant l'API pour l'instant : cette adresse est un point
# de dépendance au démarrage. Voir docs/add-k3s-node.md § « Ce qui reste fragile ».
K3S_JOIN_SERVER="${K3S_JOIN_SERVER:-https://100.64.0.1:6443}"
# Doit correspondre EXACTEMENT aux nœuds existants : un écart de version mineure
# entre membres etcd est une source classique de refus de join.
K3S_VERSION="${K3S_VERSION:-v1.34.3+k3s1}"
BASE_DOMAIN="${BASE_DOMAIN:-home.dohrm.fr}"
# Nom DNS réservé au futur load-balancer de l'API. Ajouté aux tls-san dès
# maintenant : c'est gratuit, alors que l'ajouter plus tard imposerait de
# redémarrer les API servers un par un.
LB_SAN="${LB_SAN:-k8s.${BASE_DOMAIN}}"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

NODE_NAME="$(hostname -s)"
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERREUR: %s\033[0m\n' "$*" >&2; exit 1; }
run()  { if [ "$CHECK_ONLY" = 1 ]; then info "[check] aurait exécuté: $*"; else "$@"; fi; }

[ "$(id -u)" = 0 ] || die "à exécuter en root (sudo -E)"

##############################################################################
step "0. Contrôles préalables"
##############################################################################
. /etc/os-release
info "hôte     : $NODE_NAME"
info "os       : $PRETTY_NAME  ($(uname -r))"
info "k3s visé : $K3S_VERSION"

if [ "$CHECK_ONLY" = 0 ]; then
  [ -n "${HEADSCALE_AUTHKEY:-}" ] || die "HEADSCALE_AUTHKEY non défini (cf. docs/add-k3s-node.md §3)"
  [ -n "${K3S_TOKEN:-}" ]         || die "K3S_TOKEN non défini (cf. docs/add-k3s-node.md §4)"
fi

# Un nœud avec moins de 4 Go se traînerait sous MongoDB + etcd.
mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
info "mémoire  : ${mem_mb} Mo"
[ "$mem_mb" -ge 3500 ] || die "moins de 4 Go de RAM : incompatible avec le rôle prévu"

disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
info "disque / : ${disk_gb} Go libres"
[ "$disk_gb" -ge 30 ] || die "moins de 30 Go libres sur / (etcd + images + 20 Go de PVC MongoDB)"

##############################################################################
step "1. Paquets de base"
##############################################################################
run apt-get update -qq
run apt-get install -y -qq curl ufw

##############################################################################
step "2. Headscale (client tailscale)"
##############################################################################
if command -v tailscale >/dev/null 2>&1; then
  info "tailscale déjà installé : $(tailscale version | head -1)"
else
  info "installation du client tailscale"
  run bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
fi

##############################################################################
# Casse la dépendance circulaire DNS ↔ Tailscale.
#
# VÉCU LE 2026-08-06, sur ce nœud précisément. tailscaled s'est déconnecté après
# une longue coupure réseau, et n'a plus JAMAIS pu revenir tout seul :
#
#   You are logged out. The last login error was: fetch control key:
#   Get "https://vpn.dohrm.fr/key?v=142": failed to resolve "vpn.dohrm.fr":
#   no DNS fallback candidates remain
#
# Parce que le nœud accepte le DNS de Headscale (`~.` → 100.100.100.100, soit
# tailscaled lui-même), résoudre `vpn.dohrm.fr` exige que tailscaled fonctionne.
# Une fois déconnecté, il lui faut le service qu'il fournit pour se reconnecter.
# Impasse, qui ne se répare qu'à la main sur la console KVM.
#
# Une ligne dans /etc/hosts suffit à la briser définitivement : la résolution du
# serveur de coordination ne dépend plus d'aucun résolveur.
##############################################################################
if [ "$CHECK_ONLY" = 0 ]; then
  hs_host="${HEADSCALE_URL#https://}"; hs_host="${hs_host%%/*}"; hs_host="${hs_host%%:*}"
  if grep -qE "[[:space:]]${hs_host}([[:space:]]|\$)" /etc/hosts 2>/dev/null; then
    info "/etc/hosts contient déjà $hs_host"
  else
    # Résolu depuis un résolveur public, avant que le DNS du tailnet ne prenne
    # la main sur ce nœud.
    hs_ip=$(getent ahostsv4 "$hs_host" 2>/dev/null | awk 'NR==1{print $1}')
    if [ -n "$hs_ip" ]; then
      printf '%s %s\n' "$hs_ip" "$hs_host" >> /etc/hosts
      info "/etc/hosts : $hs_ip $hs_host (brise la dépendance circulaire DNS)"
    else
      warn "impossible de résoudre $hs_host — ajoute la ligne à la main :"
      warn "    echo '<ip> $hs_host' >> /etc/hosts"
    fi
  fi
fi

run systemctl enable --now tailscaled

if [ "$CHECK_ONLY" = 0 ]; then
  if tailscale status >/dev/null 2>&1 && tailscale ip -4 >/dev/null 2>&1; then
    info "déjà enrôlé sur le tailnet"
  else
    info "enrôlement sur $HEADSCALE_URL"
    # DNS : on accepte celui de Headscale (comportement par défaut), pour être
    # ALIGNÉ sur les nœuds existants. Relevé sur vps-a7c3e9b8 le 2026-08-06 :
    #   tailscale0 → DNS Servers 100.100.100.100, DNS Domain "home.dohrm.fr ~."
    # et CoreDNS fait `forward . /etc/resolv.conf`. Donc toute résolution
    # externe des pods traverse le résolveur Headscale.
    #
    # C'est une fragilité connue à l'échelle du cluster (si tailscaled tombe sur
    # le nœud qui héberge CoreDNS, le DNS sortant des pods tombe avec lui), mais
    # la corriger sur CE nœud seulement serait pire : CoreDNS n'a qu'un replica,
    # et selon le nœud où il atterrit le comportement DNS changerait. C'est
    # exactement le genre d'incohérence qui coûte une demi-journée de debug.
    # À trancher pour les trois nœuds à la fois — noté dans docs/add-k3s-node.md.
    tailscale up \
      --login-server "$HEADSCALE_URL" \
      --authkey "$HEADSCALE_AUTHKEY" \
      --hostname "$NODE_NAME" \
      --accept-routes=false
  fi

  info "attente de l'attribution de l'IP Headscale"
  for i in $(seq 1 30); do
    NODE_IP="$(tailscale ip -4 2>/dev/null || true)"
    [ -n "$NODE_IP" ] && break
    sleep 2
  done
  [ -n "${NODE_IP:-}" ] || die "aucune IP Headscale attribuée après 60 s"
else
  NODE_IP="$(tailscale ip -4 2>/dev/null || echo '100.64.0.X')"
fi

info "IP Headscale : $NODE_IP"
info "nom MagicDNS : ${NODE_NAME}.${BASE_DOMAIN}"

# k3s démarre flannel sur tailscale0 : l'interface doit exister.
# En mode --check sur une machine encore vierge elle est légitimement absente —
# faire échouer la vérif ici la rendrait inutilisable au moment où elle sert.
if ! ip link show tailscale0 >/dev/null 2>&1; then
  if [ "$CHECK_ONLY" = 1 ]; then
    info "tailscale0 absente (normal avant enrôlement)"
  else
    die "interface tailscale0 absente après enrôlement"
  fi
fi

if [ "$CHECK_ONLY" = 0 ]; then
  info "test de joignabilité du serveur k3s existant"
  peer="${K3S_JOIN_SERVER#https://}"; peer="${peer%%:*}"
  ping -c2 -W3 "$peer" >/dev/null 2>&1 || die "$peer injoignable via le tailnet : vérifier Headscale avant de continuer"
  info "  $peer répond"
fi

##############################################################################
step "3. Pare-feu"
##############################################################################
# C'est la règle qui compte : tout le trafic inter-nœuds (API, kubelet, etcd,
# VXLAN flannel) circule sur tailscale0. On n'ouvre RIEN sur l'IP publique.
run ufw allow in on tailscale0
run ufw allow from 100.64.0.0/10 to any port 22 proto tcp
run bash -c 'ufw --force enable'
[ "$CHECK_ONLY" = 1 ] || ufw status | sed 's/^/    /'

##############################################################################
step "4. Ordonnancement systemd : k3s après tailscaled"
##############################################################################
# Les nœuds existants n'ont PAS cette dépendance : leur unit k3s ne déclare que
# `After=network-online.target`. Comme k3s est lancé avec
# `--flannel-iface=tailscale0`, un démarrage où tailscaled est plus lent que k3s
# fait échouer k3s. Ça n'a pas mordu jusqu'ici, mais c'est une fragilité au boot
# — on ne la reproduit pas sur ce nœud.
run mkdir -p /etc/systemd/system/k3s.service.d
if [ "$CHECK_ONLY" = 0 ]; then
  cat > /etc/systemd/system/k3s.service.d/10-tailscale.conf <<'EOF'
# k3s utilise --flannel-iface=tailscale0 : l'interface doit exister avant lui.
[Unit]
After=tailscaled.service
Wants=tailscaled.service
EOF
  info "drop-in écrit : /etc/systemd/system/k3s.service.d/10-tailscale.conf"
fi

##############################################################################
step "5. Configuration k3s"
##############################################################################
# On passe par /etc/rancher/k3s/config.yaml et non par des flags dans l'unit
# systemd (comme sur les nœuds existants) : le fichier est relisible, modifiable
# sans toucher à l'unit, et survit à une réinstallation de k3s.
run mkdir -p /etc/rancher/k3s
if [ "$CHECK_ONLY" = 0 ]; then
  # Heredoc NON quoté (il faut l'expansion de $NODE_IP & co) : donc PAS DE
  # BACKTICKS dans ce bloc, même en commentaire — ils seraient exécutés comme
  # substitution de commande et disparaîtraient du fichier généré. C'est
  # exactement ce qui est arrivé au premier jet. Utiliser des quotes simples.
  cat > /etc/rancher/k3s/config.yaml <<EOF
# Généré par infra/new-node-bootstrap.sh — voir docs/add-k3s-node.md
server: "$K3S_JOIN_SERVER"

# Tout le trafic cluster passe par Headscale, jamais par l'IP publique.
node-ip: "$NODE_IP"
advertise-address: "$NODE_IP"
flannel-iface: tailscale0

tls-san:
  - "$NODE_IP"
  - "${NODE_NAME}.${BASE_DOMAIN}"
  # Réservé au futur load-balancer de l'API : présent dès maintenant pour
  # éviter d'avoir à redémarrer tous les API servers le jour où il arrive.
  - "$LB_SAN"

# --- Snapshots etcd vers OVH Object Storage ------------------------------
# Les credentials viennent du Secret 'etcd-s3-config' de kube-system, déployé
# par applications/cluster-baseline. Rien de sensible sur le disque du nœud.
#
# Bucket OVH créé et Secret déployé le 2026-08-08, donc activé par défaut pour
# tout nouveau nœud. Si vous bootstrappez sur un cluster où le Secret
# 'etcd-s3-config' n'existe pas encore, repassez à false : sinon chaque
# snapshot échoue et pollue les logs.
etcd-s3: true
etcd-s3-config-secret: etcd-s3-config
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 10

# Sans ça les métriques etcd ne sont servies que sur 127.0.0.1:2381 et les
# alertes du groupe 'etcd' restent muettes en permanence.
etcd-expose-metrics: true
EOF
  chmod 600 /etc/rancher/k3s/config.yaml
  info "config écrite :"
  sed 's/^/      /' /etc/rancher/k3s/config.yaml
fi

##############################################################################
step "6. Installation de k3s en server"
##############################################################################
# PAS de --cluster-init : ce nœud REJOINT un cluster etcd existant. Utiliser
# --cluster-init ici créerait un second cluster, distinct et vide.
if command -v k3s >/dev/null 2>&1; then
  info "k3s déjà présent : $(k3s --version | head -1)"
  info "rien à faire — pour reconfigurer, éditer config.yaml puis: systemctl restart k3s"
else
  if [ "$CHECK_ONLY" = 1 ]; then
    info "[check] aurait installé k3s $K3S_VERSION en mode server"
  else
    info "installation de k3s $K3S_VERSION"
    curl -sfL https://get.k3s.io \
      | INSTALL_K3S_VERSION="$K3S_VERSION" \
        INSTALL_K3S_EXEC="server" \
        K3S_TOKEN="$K3S_TOKEN" \
        sh -
  fi
fi

##############################################################################
step "7. Vérification"
##############################################################################
if [ "$CHECK_ONLY" = 1 ]; then
  info "mode --check : aucune modification effectuée"
  exit 0
fi

info "attente que le nœud soit Ready (jusqu'à 3 min)"
for i in $(seq 1 36); do
  if k3s kubectl get node "$NODE_NAME" 2>/dev/null | grep -q ' Ready'; then
    break
  fi
  sleep 5
done

echo
k3s kubectl get nodes -o wide 2>&1 | sed 's/^/    /'
echo
info "Membres etcd (doit être 3) :"
k3s kubectl get nodes -l node-role.kubernetes.io/etcd=true --no-headers 2>/dev/null | wc -l | sed 's/^/      /'

cat <<EOF

--------------------------------------------------------------------------
Terminé sur ce nœud. Il reste à faire DEPUIS TON POSTE :

  1. Labelliser le nœud pour MongoDB prod — éditer PROD_NODES dans
     infra/label-nodes.sh (ajouter $NODE_NAME, retirer gmk-ai-master),
     commiter, puis :
         KUBECONFIG=~/.kube/home.dohrm ./infra/label-nodes.sh

  2. Déplacer le membre MongoDB : docs/critical-app-readiness.md §6.

  3. Une fois le bucket OVH créé et le Secret etcd-s3-config déployé,
     passer etcd-s3 à true dans /etc/rancher/k3s/config.yaml sur les TROIS
     nœuds, un par un, puis: systemctl restart k3s

  4. Vérifier que EtcdQuorumFragile s'est tue dans Alertmanager.
--------------------------------------------------------------------------
EOF
