#!/usr/bin/env bash
set -euo pipefail

# Bootstrap SOPS + age pour le cluster
#
# Usage:
#   ./infra/bootstrap-sops.sh
#
# Ce script :
#   1. Génère une clé age (si elle n'existe pas)
#   2. Affiche la clé publique à mettre dans .sops.yaml
#   3. Crée le secret sops-age dans le namespace argocd
#   4. Supprime le fichier clé locale

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KEY_FILE="$(mktemp)"

trap 'rm -f "$KEY_FILE"' EXIT

echo "=== Bootstrap SOPS + age ==="
echo ""

# 1. Générer la clé
age-keygen -o "$KEY_FILE" 2>&1

PUBLIC_KEY=$(grep "public key:" "$KEY_FILE" | awk '{print $NF}')

echo ""
echo "Clé publique : $PUBLIC_KEY"
echo ""

# 2. Mettre à jour .sops.yaml
if grep -q "AGE_PUBLIC_KEY_PLACEHOLDER" "$REPO_ROOT/.sops.yaml"; then
  sed -i.bak "s|AGE_PUBLIC_KEY_PLACEHOLDER|$PUBLIC_KEY|" "$REPO_ROOT/.sops.yaml"
  rm -f "$REPO_ROOT/.sops.yaml.bak"
  echo ".sops.yaml mis à jour avec la clé publique."
else
  echo "ATTENTION: .sops.yaml contient déjà une clé. Clé publique à ajouter manuellement :"
  echo "  age: $PUBLIC_KEY"
fi

echo ""

# 3. Créer le secret sur le cluster
echo "Création du secret sops-age dans argocd..."
kubectl create secret generic sops-age \
  --namespace=argocd \
  --from-file=keys.txt="$KEY_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "=== Done ==="
echo ""
echo "Prochaines étapes :"
echo "  1. Commiter .sops.yaml"
echo "  2. Remplir les vrais secrets dans les fichiers *.secret.yaml"
echo "  3. Chiffrer : sops --encrypt --in-place <fichier>.secret.yaml"
echo "  4. Commiter les fichiers chiffrés"
