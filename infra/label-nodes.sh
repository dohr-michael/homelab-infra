#!/usr/bin/env bash
##############################################################################
# Labellise les nœuds pour le placement des charges avec état.
#
# POURQUOI DES LABELS ET PAS DES HOSTNAMES DANS LES MANIFESTES
#   Les CR MongoDB sélectionnent leurs nœuds via `role.homelab/*`. Déplacer un
#   replica = déplacer un label, sans toucher au YAML ni relire un CR de
#   200 lignes. C'est aussi ce qui rend l'arrivée du 3ᵉ nœud OVH triviale.
#
#   Les labels de nœuds ne sont pas versionnables dans git (les objets Node
#   appartiennent au cluster, pas au repo) : ce script EST leur source de
#   vérité. Le modifier, le commiter, le rejouer.
#
# Idempotent : `kubectl label --overwrite` peut être relancé sans risque.
#
# Usage : KUBECONFIG=~/.kube/home.dohrm ./infra/label-nodes.sh [--dry-run]
##############################################################################
set -euo pipefail

KUBECTL=(kubectl)
[ "${1:-}" = "--dry-run" ] && KUBECTL=(kubectl --dry-run=client)

# --- Membres du replica set MongoDB de PRODUCTION -------------------------
# Topologie cible atteinte le 2026-08-06 : 3 VPS OVH, un membre par nœud, en
# régions distinctes. `gmk-ai-master` (le nœud maison) a été retiré : il ne
# porte plus que dev, RustFS et le monitoring.
#
# Ces trois nœuds sont aussi les 3 membres etcd, donc le cluster tolère
# désormais la perte d'un nœud — mais jamais deux : ne pas redémarrer deux
# serveurs en même temps.
PROD_NODES=(vps-a7c3e9b8 vps-17435151 vps-4541d883)

# --- MongoDB de DEV, RustFS, monitoring -----------------------------------
# Tout sur le nœud maison : c'est le seul avec de la RAM (48 Go) et du disque
# (950 Go). Les VPS n'ont que 8 Go / ~42 Go.
DEV_NODES=(gmk-ai-master)
RUSTFS_NODES=(gmk-ai-master)
MONITORING_NODES=(gmk-ai-master)

# --- Plan de contrôle applicatif : ArgoCD ---------------------------------
# Posé le 2026-08-08 sur vps-4541d883, le nœud le moins chargé (14 % de
# requests, 66 Go libres). ArgoCD vivait jusque-là sur vps-a7c3e9b8, qui porte
# déjà Headscale, Caddy et un membre du replica set : ~974 Mo de RSS pour huit
# pods, sur le nœud le plus sollicité et celui qui concentre toutes les entrées
# réseau. Séparer le pilotage GitOps de l'ingress réduit aussi le rayon
# d'explosion — reconstruire vps-a7c3e9b8 n'emportera plus ArgoCD avec lui.
PLATFORM_NODES=(vps-4541d883)

label() {
  local key=$1; shift
  for node in "$@"; do
    echo "  ${node}  ${key}=true"
    "${KUBECTL[@]}" label node "$node" "$key=true" --overwrite >/dev/null
  done
}

echo "role.homelab/mongodb-prod :"
label role.homelab/mongodb-prod "${PROD_NODES[@]}"
echo "role.homelab/mongodb-dev :"
label role.homelab/mongodb-dev "${DEV_NODES[@]}"
echo "role.homelab/rustfs :"
label role.homelab/rustfs "${RUSTFS_NODES[@]}"
echo "role.homelab/monitoring :"
label role.homelab/monitoring "${MONITORING_NODES[@]}"
echo "role.homelab/platform :"
label role.homelab/platform "${PLATFORM_NODES[@]}"

echo
echo "Labels role.homelab/* posés :"
kubectl get nodes \
  -L role.homelab/mongodb-prod,role.homelab/mongodb-dev,role.homelab/rustfs,role.homelab/monitoring,role.homelab/platform
