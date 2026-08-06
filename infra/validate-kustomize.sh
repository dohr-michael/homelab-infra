#!/usr/bin/env bash
# Valide `kustomize build` sur les apps sans passer par KSOPS.
#
# Le kubectl local ne supporte pas les plugins exec, donc le generator ksops
# ne peut pas tourner ici. Ce script copie chaque app dans un tmpdir, retire
# le bloc `generators:` du kustomization, et build. Les *.secret.yaml ne sont
# donc PAS validés (ils le sont par ArgoCD au sync).
#
# Usage: ./infra/validate-kustomize.sh [app...]   (défaut: toutes)
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
apps=("$@")
if [ ${#apps[@]} -eq 0 ]; then
  mapfile -t apps < <(find applications -mindepth 1 -maxdepth 1 -type d | sort)
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0

for app in "${apps[@]}"; do
  app=${app%/}
  name=$(basename "$app")
  [ -f "$app/kustomization.yaml" ] || continue
  # Copie le repo entier une seule fois pour que les chemins relatifs
  # (../../bases/...) restent résolvables.
  if [ ! -d "$tmp/repo" ]; then
    mkdir -p "$tmp/repo"
    # --others --exclude-standard : inclut les fichiers pas encore commités.
    # Sans ça, un manifeste tout juste créé n'est pas copié et le build échoue
    # sur un « no such file or directory » trompeur.
    git ls-files -z --cached --others --exclude-standard \
      | rsync -a --files-from=- --from0 . "$tmp/repo/" 2>/dev/null \
      || cp -r applications bases "$tmp/repo/" 2>/dev/null
  fi
  target="$tmp/repo/$app"
  [ -d "$target" ] || cp -r "$app" "$target"
  # Neutralise le generator ksops
  python3 - "$target/kustomization.yaml" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'(?ms)^generators:\n(?:[ \t]+.*\n|\n)*', '', s)
open(p, 'w').write(s)
PY
  if out=$(kubectl kustomize "$target" 2>&1); then
    n=$(printf '%s' "$out" | grep -c '^kind:')
    printf 'OK   %-22s %s manifests\n' "$name" "$n"
  else
    printf 'FAIL %-22s\n%s\n' "$name" "$out"
    rc=1
  fi
done

exit $rc
