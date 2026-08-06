#!/usr/bin/env bash
##############################################################################
# Initialisation root d'un VPS OVH fraîchement livré
#
# À exécuter EN ROOT SUR LE NOUVEAU SERVEUR, avant new-node-bootstrap.sh.
#
# CE QUE OVH A DÉJÀ FAIT
#   L'image OVH livre l'utilisateur `ubuntu`, dans le groupe sudo, avec un
#   fichier /etc/sudoers.d/90-cloud-init-users qui contient déjà
#   `ubuntu ALL=(ALL) NOPASSWD:ALL`, et un mot de passe temporaire à changer à
#   la première connexion.
#
#   Ce script ne recrée donc rien : il VÉRIFIE, normalise, et installe les clés
#   SSH. L'objectif est l'état constaté sur vps-a7c3e9b8, qui est ce que
#   new-node-bootstrap.sh et les scripts du repo supposent : `ssh ubuntu@<noeud>`
#   par clé, et `sudo -n` sans mot de passe.
#
# LE PIÈGE : LE MOT DE PASSE À RESET
#   Tant que le changement de mot de passe est en attente, PAM l'exige à chaque
#   ouverture de session — y compris sur une connexion par clé. Résultat : tout
#   SSH non interactif casse (`ssh ... 'cmd'`, `scp`, `sudo -E ./bootstrap.sh`).
#   C'est la première chose que ce script contrôle.
#
# DEUX PHASES, VOLONTAIREMENT SÉPARÉES
#   1. (défaut)  utilisateur + sudoers + clés. Aucun risque de perte d'accès.
#   2. --harden  durcit sshd (coupe l'auth par mot de passe et le login root).
#
#   La séparation n'est pas cosmétique : durcir sshd dans le même souffle que la
#   création de l'utilisateur, c'est risquer de se verrouiller dehors si les clés
#   n'ont pas été installées correctement. On vérifie ENTRE les deux.
#
# Usage :
#   # phase 1 — trois sources de clés possibles, dans cet ordre de priorité
#   ./new-node-root-init.sh --keys /tmp/authorized_keys
#   cat ma_cle.pub | ./new-node-root-init.sh
#   ./new-node-root-init.sh                  # reprend /root/.ssh/authorized_keys
#
#   # phase 2 — SEULEMENT après avoir vérifié l'accès (le script dit comment)
#   ./new-node-root-init.sh --harden
#
# Idempotent : relançable sans casse.
##############################################################################
set -euo pipefail

USERNAME="${USERNAME:-ubuntu}"
KEYS_FILE=""
MODE="init"

while [ $# -gt 0 ]; do
  case "$1" in
    --keys)   KEYS_FILE="${2:?--keys attend un chemin}"; shift 2 ;;
    --harden) MODE="harden"; shift ;;
    -h|--help) sed -n '2,42p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "argument inconnu: $1" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERREUR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "à exécuter en root"

##############################################################################
if [ "$MODE" = "harden" ]; then
##############################################################################
  step "Durcissement sshd"

  home=$(getent passwd "$USERNAME" | cut -d: -f6)
  ak="$home/.ssh/authorized_keys"
  nkeys=$(grep -cE '^(ssh-|ecdsa-)' "$ak" 2>/dev/null || echo 0)
  # Refuser de couper l'auth par mot de passe s'il n'y a aucune clé, sinon on
  # ferme la seule porte restante.
  [ "$nkeys" -ge 1 ] || die "aucune clé publique dans $ak — durcir maintenant te verrouillerait dehors"
  info "$nkeys clé(s) présente(s) pour $USERNAME"

  ##########################################################################
  # Le nom du fichier est le point critique.
  #
  # sshd retient la PREMIÈRE valeur trouvée pour une directive, et
  # /etc/ssh/sshd_config a son `Include /etc/ssh/sshd_config.d/*.conf` en
  # ligne 12, donc les drop-ins sont lus avant le reste — mais entre eux,
  # c'est l'ordre alphabétique.
  #
  # Relevé sur vps-a7c3e9b8 le 2026-08-06 :
  #     50-cloud-init.conf        → PasswordAuthentication yes
  #     60-cloudimg-settings.conf → PasswordAuthentication no
  # Le `no` de l'image OVH est donc silencieusement battu par le `yes` de
  # cloud-init. D'où le préfixe 10- : il faut trier AVANT 50-cloud-init.conf.
  ##########################################################################
  conf=/etc/ssh/sshd_config.d/10-homelab.conf
  tmp=$(mktemp)
  cat > "$tmp" <<'EOF'
# Durcissement homelab — voir infra/new-node-root-init.sh
#
# Préfixe 10- indispensable : sshd garde la première valeur lue et
# 50-cloud-init.conf réactive PasswordAuthentication yes.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
EOF
  install -m 0644 -o root -g root "$tmp" "$conf"
  rm -f "$tmp"
  info "écrit : $conf"

  # Valider AVANT de recharger : une config invalide + un reload, et sshd
  # refuse de redémarrer.
  sshd -t || { rm -f "$conf"; die "config sshd invalide, drop-in retiré, rien n'a été rechargé"; }
  info "sshd -t : OK"

  # `reload` et surtout PAS `restart` : reload ne coupe pas les sessions
  # établies. Si quelque chose cloche, la session courante reste ouverte pour
  # réparer.
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
  info "sshd rechargé (sessions en cours préservées)"

  echo
  info "Valeurs effectives :"
  sshd -T | grep -iE '^(permitrootlogin|passwordauthentication|pubkeyauthentication)' | sed 's/^/      /'

  cat <<EOF

--------------------------------------------------------------------------
NE FERME PAS cette session avant d'avoir vérifié, depuis ton poste :

    ssh ${USERNAME}@<nouveau-noeud> 'echo ok && sudo -n true && echo sudo-ok'

Si ça échoue : tu es encore root ici, retire $conf et recharge sshd.
Récupération de dernier recours si tout est perdu : mode rescue OVH.
--------------------------------------------------------------------------
EOF
  exit 0
fi

##############################################################################
step "1. Utilisateur $USERNAME"
##############################################################################
if id "$USERNAME" >/dev/null 2>&1; then
  info "$USERNAME fourni par l'image OVH (uid $(id -u "$USERNAME")) — non recréé"
else
  # Cas d'une image sans utilisateur pré-créé. Pas de --uid forcé : laisser le
  # système choisir évite un conflit si 1000 est déjà pris.
  useradd --create-home --shell /bin/bash "$USERNAME"
  info "$USERNAME créé"
fi

usermod -aG sudo "$USERNAME"
info "groupes : $(id -nG "$USERNAME")"

shell=$(getent passwd "$USERNAME" | cut -d: -f7)
[ "$shell" = /bin/bash ] || warn "shell inattendu ($shell) — attendu /bin/bash"

##############################################################################
step "2. Mot de passe : lever le changement forcé"
##############################################################################
# Sur le nœud de référence (vps-a7c3e9b8), l'état sain est :
#     passwd -S ubuntu  ->  ubuntu P <date> 0 99999 7 -1
# soit un mot de passe utilisable ("P") et aucun changement en attente.
#
# Sur un VPS neuf, OVH pose un mot de passe temporaire avec `Last password
# change: 0` (epoch) : PAM exige alors un changement à chaque session, ce qui
# fait échouer tout SSH non interactif.
pwstate=$(passwd -S "$USERNAME" | awk '{print $2}')
lastchg=$(awk -F: -v u="$USERNAME" '$1==u{print $3}' /etc/shadow)
info "état du mot de passe : $pwstate   (dernier changement, en jours epoch : ${lastchg:-?})"

case "$pwstate" in
  P) info "mot de passe utilisable" ;;
  L) warn "mot de passe VERROUILLÉ : pas de secours par la console OVH" ;;
  NP) warn "AUCUN mot de passe : n'importe qui sur la console entre sans rien" ;;
esac

if [ "${lastchg:-1}" = "0" ]; then
  ##########################################################################
  # On ne touche PAS au mot de passe ici, volontairement.
  #
  # Lever le drapeau sans changer le mot de passe laisserait actif celui fourni
  # par OVH — transmis par un canal qu'on ne contrôle pas. Or c'est la seule
  # protection de la console de secours. Donc : on s'arrête et on demande un
  # vrai changement, ce qui lève le drapeau au passage.
  ##########################################################################
  warn ""
  warn "CHANGEMENT DE MOT DE PASSE EN ATTENTE — à traiter avant de continuer."
  warn "Tant qu'il est en attente, PAM le réclame même sur une connexion par"
  warn "clé, et tout SSH non interactif échoue (scp, ssh 'cmd', bootstrap)."
  warn ""
  warn "Depuis cette session root, définis-en un vrai (le mot de passe OVH est"
  warn "arrivé par un canal que tu ne maîtrises pas) :"
  warn "      passwd $USERNAME"
  warn ""
  warn "Puis relance ce script. Il reprendra où il en est."
  die "arrêt : mot de passe de $USERNAME à changer d'abord"
fi

# Aligner sur la référence : aucune expiration, pas de délai minimum.
chage -m 0 -M 99999 -W 7 -E -1 "$USERNAME"
info "expiration alignée sur le nœud de référence (aucune)"

##############################################################################
step "3. sudo sans mot de passe"
##############################################################################
existing=$(grep -rlE "^\s*$USERNAME\s+ALL=\(ALL\)\s+NOPASSWD:ALL" /etc/sudoers.d/ 2>/dev/null || true)
if [ -n "$existing" ]; then
  info "NOPASSWD déjà accordé par : $existing"
  info "(fourni par cloud-init sur les images OVH)"
fi

# On pose quand même une règle explicite au nom du repo : cloud-init peut
# régénérer ou supprimer son propre fichier, et l'accès sudo non interactif est
# une dépendance dure des scripts du repo.
sudoers=/etc/sudoers.d/90-homelab-"$USERNAME"
tmp=$(mktemp)
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$USERNAME" > "$tmp"
# Un fichier sudoers malformé casse sudo ENTIÈREMENT, y compris pour réparer :
# on valide dans un fichier temporaire avant de l'installer.
visudo -cqf "$tmp" || { rm -f "$tmp"; die "fichier sudoers invalide, rien installé"; }
# 0440 : sudo refuse de lire un fichier de règles inscriptible par le groupe.
install -m 0440 -o root -g root "$tmp" "$sudoers"
rm -f "$tmp"
info "écrit : $sudoers"
visudo -cqf /etc/sudoers && info "sudoers global toujours valide"

##############################################################################
step "4. Clés SSH"
##############################################################################
home=$(getent passwd "$USERNAME" | cut -d: -f6)
ssh_dir="$home/.ssh"
ak="$ssh_dir/authorized_keys"
src=$(mktemp)

if [ -n "$KEYS_FILE" ]; then
  [ -s "$KEYS_FILE" ] || die "$KEYS_FILE vide ou absent"
  cat "$KEYS_FILE" > "$src"; info "source : $KEYS_FILE"
elif [ ! -t 0 ]; then
  cat > "$src"; info "source : stdin"
elif [ -s /root/.ssh/authorized_keys ]; then
  cat /root/.ssh/authorized_keys > "$src"; info "source : /root/.ssh/authorized_keys"
else
  rm -f "$src"
  die "aucune clé fournie. Utiliser --keys <fichier>, ou l'entrée standard.
       Depuis ton poste, pour reprendre les clés déjà en place sur le cluster :
         ssh ubuntu@vps-a7c3e9b8 'sudo cat /home/ubuntu/.ssh/authorized_keys' \\
           | ssh root@<nouveau-noeud> '/tmp/new-node-root-init.sh'"
fi

nkeys=$(grep -cE '^(ssh-|ecdsa-)' "$src" || true)
[ "${nkeys:-0}" -ge 1 ] || { rm -f "$src"; die "aucune clé publique valide reconnue dans la source"; }
info "$nkeys clé(s) publique(s) trouvée(s) :"
# N'afficher que le commentaire terminal, pas le matériel de la clé.
awk '{ print "      - " $1 " …" ($3 ? $3 : "(sans commentaire)") }' "$src"

install -d -m 0700 -o "$USERNAME" -g "$USERNAME" "$ssh_dir"
if [ -s "$ak" ]; then
  # Fusion sans doublon : ne jamais écraser des clés déjà autorisées, on ne
  # sait pas qui en dépend.
  before=$(grep -cE '^(ssh-|ecdsa-)' "$ak" || true)
  cat "$ak" "$src" | awk 'NF && !seen[$0]++' > "$src.merged"
  install -m 0600 -o "$USERNAME" -g "$USERNAME" "$src.merged" "$ak"
  after=$(grep -cE '^(ssh-|ecdsa-)' "$ak" || true)
  info "authorized_keys fusionné : $before -> $after clé(s)"
  rm -f "$src.merged"
else
  install -m 0600 -o "$USERNAME" -g "$USERNAME" "$src" "$ak"
  info "authorized_keys créé"
fi
rm -f "$src"
ls -la "$ak" | sed 's/^/      /'

##############################################################################
step "5. Réglages de base"
##############################################################################
# UTC comme les nœuds existants : des horodatages cohérents entre membres etcd
# et dans les logs, c'est ce qui rend un incident lisible.
current_tz=$(timedatectl show -p Timezone --value)
if [ "$current_tz" = "Etc/UTC" ] || [ "$current_tz" = "UTC" ]; then
  info "timezone déjà en UTC"
else
  timedatectl set-timezone Etc/UTC
  info "timezone : $current_tz -> Etc/UTC"
fi

info "hostname actuel : $(hostnamectl --static)"
warn "Le hostname devient le nom du nœud Kubernetes ET son nom MagicDNS"
warn "(<hostname>.home.dohrm.fr). Le changer APRÈS l'installation de k3s"
warn "créerait un second objet Node. Si tu veux le changer, c'est MAINTENANT :"
warn "    hostnamectl set-hostname <nom> && reboot"

##############################################################################
step "6. Terminé — phase 1"
##############################################################################
cat <<EOF

--------------------------------------------------------------------------
Vérifie MAINTENANT, depuis ton poste, sans fermer cette session root :

    ssh ${USERNAME}@<nouveau-noeud> 'echo ok && sudo -n true && echo sudo-ok'

Les deux « ok » doivent s'afficher. Ensuite seulement :

  1. (optionnel mais recommandé) durcir sshd :
         ./new-node-root-init.sh --harden

     À noter : sur vps-a7c3e9b8 l'auth par mot de passe est ACTIVE, parce que
     50-cloud-init.conf bat le 60-cloudimg-settings.conf de l'image. Les nœuds
     existants gagneraient le même traitement.

  2. rejoindre le cluster — voir docs/add-k3s-node.md :
         sudo -E ./new-node-bootstrap.sh
--------------------------------------------------------------------------
EOF
