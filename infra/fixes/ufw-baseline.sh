#!/usr/bin/env bash
##############################################################################
# Pare-feu de base pour un nœud k3s — tout passe par Headscale
#
# À exécuter EN ROOT sur un VPS dont le pare-feu est absent ou permissif.
# Cible immédiate : vps-17435151, qui expose 22, 6443 et 10250 sur Internet
# (IPv4 ET IPv6). Voir infra/fixes/README.md § « Constat 1 ».
#
# Reproduit la configuration constatée sur vps-4541d883, qui est propre :
# scan externe → aucun port ouvert en IPv6, et seuls les ports détournés par
# ServiceLB en IPv4 (traités séparément par traefik-lb-sourceranges.yaml).
#
# ⚠️ RISQUE DE PERTE D'ACCÈS SSH
#   Ce script n'autorise SSH QUE depuis 100.64.0.0/10. Si tu te connectes
#   actuellement via l'IP PUBLIQUE, tu perds la session en activant ufw.
#   Il refuse donc de continuer si la session courante n'arrive pas par le
#   tailnet — sauf ALLOW_PUBLIC_SSH=1 explicite.
#
# Usage :
#   sudo ./ufw-baseline.sh --check     # montre ce qui serait fait
#   sudo ./ufw-baseline.sh
##############################################################################
set -euo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERREUR: %s\033[0m\n' "$*" >&2; exit 1; }
run()  { if [ "$CHECK_ONLY" = 1 ]; then info "[check] $*"; else "$@"; fi; }

[ "$(id -u)" = 0 ] || die "à exécuter en root"

##############################################################################
step "0. Garde-fou : par où arrive la session courante ?"
##############################################################################
peer="${SSH_CLIENT%% *}"
info "SSH_CLIENT source : ${peer:-<inconnue, session locale ?>}"

case "$peer" in
  100.64.*|100.6[5-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*)
    info "session via le tailnet : activer ufw ne la coupera pas" ;;
  "")
    warn "pas de session SSH détectée (console ?) — poursuite" ;;
  *)
    if [ "${ALLOW_PUBLIC_SSH:-0}" = 1 ]; then
      warn "session via $peer (hors tailnet) mais ALLOW_PUBLIC_SSH=1 : poursuite"
    else
      die "session SSH via $peer, hors 100.64.0.0/10.
       Activer ufw maintenant COUPERAIT cette connexion.
       Reconnecte-toi par le tailnet :  ssh ubuntu@<ip-100.64.x>
       ou, en connaissance de cause :   ALLOW_PUBLIC_SSH=1 sudo -E $0"
    fi ;;
esac

# tailscale0 doit exister : c'est l'interface sur laquelle tout est autorisé.
ip link show tailscale0 >/dev/null 2>&1 || die "interface tailscale0 absente — le nœud n'est pas sur le tailnet"

##############################################################################
step "1. ufw installé et IPv6 activé"
##############################################################################
command -v ufw >/dev/null 2>&1 || run apt-get install -y -qq ufw

# Sans IPV6=yes, ufw ne filtre QUE l'IPv4 : c'est exactement le trou par lequel
# 22, 6443 et 10250 sont joignables en IPv6 sur vps-17435151.
if grep -qE '^IPV6=yes' /etc/default/ufw; then
  info "IPV6=yes déjà positionné"
else
  run sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
  info "IPV6 activé dans /etc/default/ufw"
fi

##############################################################################
step "2. Politiques par défaut"
##############################################################################
run ufw default deny incoming
run ufw default allow outgoing
run ufw default deny routed

##############################################################################
step "3. Règles"
##############################################################################
# LA règle qui compte : tout le trafic inter-nœuds (API 6443, kubelet 10250,
# etcd 2379-2380, VXLAN flannel 8472) circule sur tailscale0. Rien n'a besoin
# d'être ouvert sur l'IP publique.
run ufw allow in on tailscale0
# SSH depuis le tailnet uniquement. 100.64.0.0/10 est la plage Headscale.
run ufw allow from 100.64.0.0/10 to any port 22 proto tcp

##############################################################################
step "4. Activation"
##############################################################################
run bash -c 'ufw --force enable'

if [ "$CHECK_ONLY" = 1 ]; then
  info "mode --check : rien n'a été modifié"
  exit 0
fi

echo
ufw status verbose | sed 's/^/    /'

cat <<'EOF'

--------------------------------------------------------------------------
NE FERME PAS cette session avant d'avoir vérifié depuis ton poste :

    ssh ubuntu@<ip-100.64.x> 'echo ok'

Puis, depuis une machine HORS VPN (ou en coupant tailscale), confirmer que
plus rien ne répond sur l'IP publique — 6443 et 10250 en particulier :

    for p in 22 6443 10250; do
      nc -z -w3 <ip-publique> $p && echo "$p OUVERT" || echo "$p fermé"
    done

Rappel : ça ne referme PAS 81/444/30594/31767, qui passent par ServiceLB et
contournent ufw. C'est l'objet de traefik-lb-sourceranges.yaml.
--------------------------------------------------------------------------
EOF
