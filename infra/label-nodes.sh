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
# État actuel : 2 VPS OVH + le nœud maison, pour avoir 3 votants et donc un
# quorum qui survit à la perte d'un nœud.
# À l'arrivée du 3ᵉ VPS OVH : ajouter le nouveau nœud ici, retirer
# gmk-ai-master, puis voir docs/critical-app-readiness.md.
PROD_NODES=(vps-a7c3e9b8 vps-17435151 vps-4541d883)

# --- MongoDB de DEV, RustFS, monitoring -----------------------------------
# Tout sur le nœud maison : c'est le seul avec de la RAM (48 Go) et du disque
# (950 Go). Les VPS n'ont que 8 Go / ~42 Go.
DEV_NODES=(gmk-ai-master)
RUSTFS_NODES=(gmk-ai-master)
MONITORING_NODES=(gmk-ai-master)

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

echo
echo "Labels role.homelab/* posés :"
kubectl get nodes \
  -L role.homelab/mongodb-prod,role.homelab/mongodb-dev,role.homelab/rustfs,role.homelab/monitoring
