#!/usr/bin/env bash
# Usage: sudo ./setup-frpc.sh <game>
#   ex:  sudo ./setup-frpc.sh conan
#        sudo ./setup-frpc.sh minecraft
#
# Prérequis (une seule fois) :
#   cp applications/frp/clients/.env.example applications/frp/clients/.env
#   # éditer .env avec FRP_SERVER et FRP_TOKEN
set -euo pipefail

GAME="${1:-}"
FRP_VERSION="0.62.1"
ARCH="$(uname -m)"
CLIENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(git -C "$CLIENTS_DIR" rev-parse --show-toplevel)"

# --- validation ---
if [[ -z "$GAME" ]]; then
  echo "Usage: $0 <game>"
  echo "Jeux disponibles : $(ls "$CLIENTS_DIR"/*.toml | xargs -n1 basename | sed 's/\.toml//' | tr '\n' ' ')"
  exit 1
fi

CONFIG_SRC="$CLIENTS_DIR/$GAME.toml"
if [[ ! -f "$CONFIG_SRC" ]]; then
  echo "Erreur : pas de config pour '$GAME' ($CONFIG_SRC introuvable)"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Erreur : ce script doit être lancé en root (sudo)"
  exit 1
fi

ENV_FILE="$CLIENTS_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Erreur : $ENV_FILE absent."
  echo "Créer le fichier à partir du template :"
  echo "  cp $CLIENTS_DIR/.env.example $ENV_FILE"
  echo "  # puis éditer avec FRP_SERVER et FRP_TOKEN"
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

if [[ -z "${FRP_SERVER:-}" || -z "${FRP_TOKEN:-}" ]]; then
  echo "Erreur : FRP_SERVER et FRP_TOKEN doivent être définis dans $ENV_FILE"
  exit 1
fi

# --- git pull ---
echo ">>> Mise à jour du repo..."
git -C "$REPO_DIR" pull --ff-only

# --- installation frpc ---
case "$ARCH" in
  x86_64)  ARCH_TAG="amd64" ;;
  aarch64) ARCH_TAG="arm64" ;;
  armv7l)  ARCH_TAG="arm" ;;
  *)       echo "Architecture non supportée : $ARCH"; exit 1 ;;
esac

INSTALLED_VERSION="$(frpc --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || true)"
if [[ "$INSTALLED_VERSION" != "$FRP_VERSION" ]]; then
  echo ">>> Installation de frpc v$FRP_VERSION ($ARCH_TAG)..."
  TMP="$(mktemp -d)"
  curl -fsSL "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${ARCH_TAG}.tar.gz" \
    | tar -xz -C "$TMP"
  install -m 755 "$TMP/frp_${FRP_VERSION}_linux_${ARCH_TAG}/frpc" /usr/local/bin/frpc
  rm -rf "$TMP"
  echo "    frpc $(frpc --version) installé"
else
  echo ">>> frpc v$FRP_VERSION déjà installé"
fi

# --- config ---
echo ">>> Déploiement de la config ($GAME)..."
mkdir -p /etc/frp

# Construit les expressions sed depuis toutes les variables du .env
SED_ARGS=()
while IFS='=' read -r key value; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  SED_ARGS+=(-e "s|\${${key}}|${value}|g")
done < "$ENV_FILE"

sed "${SED_ARGS[@]}" "$CONFIG_SRC" > /etc/frp/frpc.toml

# --- service systemd ---
SERVICE_FILE="/etc/systemd/system/frpc.service"
if [[ ! -f "$SERVICE_FILE" ]]; then
  echo ">>> Installation du service systemd..."
  cp "$CLIENTS_DIR/frpc.service" "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl enable frpc
fi

# --- (re)démarrage ---
echo ">>> (Re)démarrage de frpc..."
systemctl restart frpc
systemctl --no-pager status frpc

echo ""
echo "OK — frpc actif pour '$GAME'"
echo "  Logs : journalctl -u frpc -f"
