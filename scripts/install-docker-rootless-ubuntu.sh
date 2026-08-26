#!/usr/bin/env bash
#
# install-docker-rootless-ubuntu.sh
# ---------------------------------------------------------------------------
# Installe Docker Engine + Docker Compose v2 en mode *rootless* sur Ubuntu
# (22.04 / 24.04), de façon compatible avec des identités **temporaires**
# distribuées par step-ca (certificats SSH de courte durée, comptes éphémères).
#
# Deux modes :
#
#   --mode shared    (défaut)  Un compte de service permanent (dockersvc) porte
#                              le démon rootless. Sa socket est exposée dans
#                              /run/docker-rootless/docker.sock au groupe
#                              docker-rootless : n'importe quelle identité
#                              temporaire membre de ce groupe pilote Docker
#                              sans qu'aucun état ne dépende de son compte.
#
#   --mode per-user            Chaque utilisateur (y compris éphémère) obtient
#                              son propre démon rootless. Un helper root
#                              (sudo, sans mot de passe pour le groupe) alloue
#                              à la volée les plages subuid/subgid, active le
#                              linger et place le data-root hors du HOME dans
#                              /var/lib/docker-rootless/<user>, pour survivre
#                              à un HOME volatile.
#
# Intégration step-ca (optionnelle, cf. --ca-url / --ca-fingerprint) :
#   - installation de step-cli ;
#   - bootstrap + ajout de la racine step-ca au magasin de confiance système
#     (registres privés en HTTPS, appels `step ca certificate`) ;
#   - --configure-sshd : sshd fait confiance à la CA SSH utilisateur de
#     step-ca (ajout *additif*, aucune méthode d'authentification retirée).
#
# Usage :  sudo ./install-docker-rootless-ubuntu.sh [options]
#          sudo ./install-docker-rootless-ubuntu.sh --help
# ---------------------------------------------------------------------------

set -Eeuo pipefail

# --- Réglages par défaut ---------------------------------------------------
SVC_USER="dockersvc"
ACCESS_GROUP="docker-rootless"
MODE="shared"
SOCKET_DIR="/run/docker-rootless"
DATA_ROOT_BASE="/var/lib/docker-rootless"
SUBID_BASE=500000            # début de la zone d'allocation subuid/subgid
SUBID_SIZE=65536             # taille d'une plage par utilisateur
UNPRIV_PORT_START=80         # ports >= 80 ouvrables sans privilège
# Pilote de port RootlessKit : "slirp4netns" conserve l'IP source réelle des
# clients (indispensable aux logs Vaultwarden et à fail2ban) ; "builtin" est
# plus rapide mais fait apparaître toutes les connexions en 127.0.0.1.
PORT_DRIVER="slirp4netns"
CA_URL=""
CA_FINGERPRINT=""
CA_ROOT_FILE=""
CONFIGURE_SSHD=0
KEEP_ROOTFUL=0
DRY_RUN=0

STEP_CLI_VERSION="${STEP_CLI_VERSION:-}"   # ex. 0.28.7 ; vide = dernière version

# --- Journalisation --------------------------------------------------------
if [[ -t 1 ]]; then
  C_INFO=$'\033[1;34m'; C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'
  C_ERR=$'\033[1;31m';  C_OFF=$'\033[0m'
else
  C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""
fi
log()  { printf '%s==>%s %s\n'  "$C_INFO" "$C_OFF" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_OK"   "$C_OFF" "$*"; }
warn() { printf '%satt.%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
err()  { printf '%serr.%s %s\n' "$C_ERR"  "$C_OFF" "$*" >&2; }
die()  { err "$*"; exit 1; }

trap 'err "Échec à la ligne $LINENO (commande : $BASH_COMMAND)"' ERR

run() {
  if (( DRY_RUN )); then
    printf '     [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

usage() {
  sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options :
  --mode shared|per-user   Modèle d'accès (défaut : shared)
  --user NOM               Compte de service du démon rootless (défaut : dockersvc)
  --group NOM              Groupe autorisé à piloter Docker (défaut : docker-rootless)
  --socket-dir CHEMIN      Répertoire de la socket partagée (défaut : /run/docker-rootless)
  --data-root-base CHEMIN  Base des data-roots en mode per-user (défaut : /var/lib/docker-rootless)
  --port-start N           net.ipv4.ip_unprivileged_port_start (défaut : 80 ; 1024 pour désactiver)
  --port-driver NOM        slirp4netns (défaut, IP source réelle) ou builtin (plus rapide)
  --ca-url URL             URL de step-ca, ex. https://ca.exemple.lu:8443
  --ca-fingerprint FP      Empreinte SHA-256 de la racine step-ca (obligatoire avec --ca-url)
  --ca-root FICHIER        Racine PEM déjà en votre possession (alternative à --ca-url)
  --configure-sshd         Fait confiance à la CA SSH utilisateur de step-ca dans sshd
  --keep-rootful           Ne désactive pas le démon Docker root (déconseillé)
  --dry-run                Affiche les actions sans rien modifier
  -h, --help               Cette aide
EOF
}

# --- Analyse des arguments -------------------------------------------------
parse_args() {
  while (( $# )); do
    case "$1" in
      --mode)            MODE="${2:?}"; shift 2 ;;
      --user)            SVC_USER="${2:?}"; shift 2 ;;
      --group)           ACCESS_GROUP="${2:?}"; shift 2 ;;
      --socket-dir)      SOCKET_DIR="${2:?}"; shift 2 ;;
      --data-root-base)  DATA_ROOT_BASE="${2:?}"; shift 2 ;;
      --port-start)      UNPRIV_PORT_START="${2:?}"; shift 2 ;;
      --port-driver)     PORT_DRIVER="${2:?}"; shift 2 ;;
      --ca-url)          CA_URL="${2:?}"; shift 2 ;;
      --ca-fingerprint)  CA_FINGERPRINT="${2:?}"; shift 2 ;;
      --ca-root)         CA_ROOT_FILE="${2:?}"; shift 2 ;;
      --configure-sshd)  CONFIGURE_SSHD=1; shift ;;
      --keep-rootful)    KEEP_ROOTFUL=1; shift ;;
      --dry-run)         DRY_RUN=1; shift ;;
      -h|--help)         usage; exit 0 ;;
      *)                 usage >&2; die "Option inconnue : $1" ;;
    esac
  done

  case "$PORT_DRIVER" in
    slirp4netns|builtin|pasta) ;;
    *) die "--port-driver doit valoir slirp4netns, pasta ou builtin (reçu : $PORT_DRIVER)" ;;
  esac
  case "$MODE" in
    shared|per-user) ;;
    *) die "--mode doit valoir 'shared' ou 'per-user' (reçu : $MODE)" ;;
  esac
  if [[ -n "$CA_URL" && -z "$CA_FINGERPRINT" ]]; then
    die "--ca-url exige --ca-fingerprint"
  fi
  if [[ -n "$CA_ROOT_FILE" && ! -r "$CA_ROOT_FILE" ]]; then
    die "Racine illisible : $CA_ROOT_FILE"
  fi
  if (( CONFIGURE_SSHD )) && [[ -z "$CA_URL" ]]; then
    die "--configure-sshd exige --ca-url/--ca-fingerprint"
  fi
}

# --- Contrôles préalables --------------------------------------------------
preflight() {
  # En --dry-run on se contente d'avertir : le script doit rester lisible/testable
  # depuis un poste quelconque avant d'être joué sur le serveur cible.
  local fatal=die
  if (( DRY_RUN )); then fatal=warn; fi
  (( EUID == 0 )) || "$fatal" "Ce script doit être lancé en root (sudo)."
  [[ -d /run/systemd/system ]] || "$fatal" "systemd est requis (session utilisateur systemd/logind)."

  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || warn "Distribution '${ID:-inconnue}' : script prévu pour Ubuntu, poursuite."
  OS_CODENAME="${VERSION_CODENAME:-}"
  if [[ -z "$OS_CODENAME" ]]; then
    "$fatal" "Impossible de déterminer le nom de code Ubuntu."
    OS_CODENAME="noble"
  fi
  ARCH="$(dpkg --print-architecture)"

  if [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
    warn "cgroup v2 absent : les limites CPU/mémoire ne seront pas disponibles en rootless."
  fi

  log "Ubuntu $OS_CODENAME ($ARCH) — mode $MODE — compte de service : $SVC_USER"
}

apt_get() { run env DEBIAN_FRONTEND=noninteractive apt-get "$@"; }

# --- 1. Prérequis système --------------------------------------------------
install_prerequisites() {
  log "Installation des prérequis rootless (uidmap, dbus-user-session, …)"
  apt_get update -qq
  apt_get install -y --no-install-recommends \
    ca-certificates curl gnupg jq acl \
    uidmap dbus-user-session fuse-overlayfs slirp4netns iptables

  # pasta (passt) : réseau rootless plus rapide que slirp4netns, présent à
  # partir d'Ubuntu 24.04 ; absent ailleurs, ce n'est pas bloquant.
  if apt-cache show passt >/dev/null 2>&1; then
    apt_get install -y --no-install-recommends passt || warn "passt non installé (facultatif)."
  fi
  ok "Prérequis installés"
}

# --- 2. Noyau : modules, sysctl, AppArmor ----------------------------------
configure_kernel() {
  log "Configuration noyau (modules netfilter, sysctl, AppArmor)"

  run install -m 0644 /dev/stdin /etc/modules-load.d/docker-rootless.conf <<'EOF'
# Requis par le mode rootless de Docker (port forwarding / NAT)
ip_tables
ip6_tables
iptable_nat
ip6table_nat
netfilter
EOF
  for m in ip_tables ip6_tables iptable_nat ip6table_nat; do
    run modprobe "$m" 2>/dev/null || true
  done

  {
    echo "# Ports privilégiés ouvrables sans capacité (rootless : 80/443)"
    echo "net.ipv4.ip_unprivileged_port_start = ${UNPRIV_PORT_START}"
    echo "# Espaces de noms utilisateur : indispensables au mode rootless"
    echo "user.max_user_namespaces = 28633"
    if [[ -e /proc/sys/kernel/unprivileged_userns_clone ]]; then
      echo "kernel.unprivileged_userns_clone = 1"
    fi
    # Ubuntu >= 23.10 : restriction AppArmor des userns non privilégiés.
    # On garde la restriction active et on autorise finement rootlesskit
    # via un profil dédié (cf. configure_apparmor).
    :
  } > /tmp/docker-rootless.sysctl
  run install -m 0644 /tmp/docker-rootless.sysctl /etc/sysctl.d/99-docker-rootless.conf
  rm -f /tmp/docker-rootless.sysctl
  run sysctl --quiet --system || warn "sysctl --system a signalé une erreur (à vérifier)."
  ok "Paramètres noyau appliqués"
}

configure_apparmor() {
  [[ -d /etc/apparmor.d ]] || return 0
  [[ -e /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]] || return 0

  local rk_path profile_name
  rk_path="$(command -v rootlesskit || true)"
  [[ -n "$rk_path" ]] || { warn "rootlesskit introuvable : profil AppArmor non créé."; return 0; }

  # Convention Docker : chemin absolu, '/' initial retiré, '/' -> '.'
  profile_name="$(printf '%s' "${rk_path#/}" | tr '/' '.')"

  log "Profil AppArmor pour rootlesskit ($profile_name)"
  run install -m 0644 /dev/stdin "/etc/apparmor.d/${profile_name}" <<EOF
abi <abi/4.0>,
include <tunables/global>

"${rk_path}" flags=(unconfined) {
  userns,
  include if exists <local/${profile_name}>
}
EOF
  if systemctl is-active --quiet apparmor.service; then
    run systemctl restart apparmor.service || warn "Rechargement AppArmor en échec."
  fi
  ok "AppArmor autorise les user namespaces pour rootlesskit"
}

# --- 3. Docker Engine + Compose v2 -----------------------------------------
install_docker() {
  log "Dépôt APT Docker et installation des paquets"
  run install -m 0755 -d /etc/apt/keyrings
  if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
    run curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc
    run chmod a+r /etc/apt/keyrings/docker.asc
  fi
  run install -m 0644 /dev/stdin /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${OS_CODENAME} stable
EOF

  apt_get update -qq
  apt_get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
  ok "Docker Engine, Compose v2 et l'outillage rootless sont installés"
}

disable_rootful_daemon() {
  if (( KEEP_ROOTFUL )); then
    warn "Démon Docker root conservé (--keep-rootful) : il coexiste avec le rootless."
    return 0
  fi
  log "Désactivation du démon Docker privilégié"
  run systemctl disable --now docker.service docker.socket 2>/dev/null || true
  run systemctl mask docker.service docker.socket 2>/dev/null || true
  ok "Seul le démon rootless tournera sur cette machine"
}

# --- 4. step-ca ------------------------------------------------------------
install_step_cli() {
  if command -v step >/dev/null 2>&1; then
    ok "step-cli déjà présent ($(step version 2>/dev/null | head -n1))"
    return 0
  fi
  log "Installation de step-cli"
  if (( DRY_RUN )); then
    printf '     [dry-run] installation de step-cli (dépôt Smallstep, sinon .deb GitHub)\n'
    return 0
  fi

  install -m 0755 -d /etc/apt/keyrings
  if curl -fsSL https://packages.smallstep.com/keys/apt/repo-signing-key.gpg \
        -o /etc/apt/keyrings/smallstep.asc 2>/dev/null; then
    run install -m 0644 /dev/stdin /etc/apt/sources.list.d/smallstep.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/smallstep.asc] https://packages.smallstep.com/stable/debian debs main
EOF
    if apt_get update -qq && apt_get install -y step-cli; then
      ok "step-cli installé depuis le dépôt Smallstep"
      return 0
    fi
    warn "Dépôt Smallstep indisponible, bascule sur le paquet .deb GitHub."
    rm -f /etc/apt/sources.list.d/smallstep.list
    apt_get update -qq || true
  fi

  local version="$STEP_CLI_VERSION" url deb
  if [[ -z "$version" ]]; then
    version="$(curl -fsSL https://api.github.com/repos/smallstep/cli/releases/latest \
      | jq -r '.tag_name' | sed 's/^v//')" || true
  fi
  [[ -n "$version" && "$version" != "null" ]] || \
    die "Version de step-cli indéterminable : relancez avec STEP_CLI_VERSION=x.y.z."
  url="https://dl.smallstep.com/gh-release/cli/gh-release-header/v${version}/step-cli_${version}_${ARCH}.deb"
  deb="$(mktemp --suffix=.deb)"
  run curl -fsSL "$url" -o "$deb" || die "Téléchargement de step-cli en échec : $url"
  run apt-get install -y "$deb"
  rm -f "$deb"
  ok "step-cli ${version} installé"
}

trust_ca_certificate() {
  local src="$1" dest=/usr/local/share/ca-certificates/step-ca-root.crt
  run install -m 0644 "$src" "$dest"
  run update-ca-certificates >/dev/null
  ok "Racine step-ca ajoutée au magasin de confiance système"
}

bootstrap_stepca() {
  [[ -n "$CA_URL" || -n "$CA_ROOT_FILE" ]] || {
    log "step-ca non configuré (ni --ca-url ni --ca-root) : étape ignorée"
    return 0
  }

  if [[ -n "$CA_URL" ]]; then
    install_step_cli
    log "Bootstrap step-ca sur $CA_URL"
    run step ca bootstrap --ca-url "$CA_URL" --fingerprint "$CA_FINGERPRINT" \
      --install --force
    if [[ -r /root/.step/certs/root_ca.crt ]]; then
      trust_ca_certificate /root/.step/certs/root_ca.crt
    fi

    # Le compte de service doit lui aussi connaître la CA (registres privés,
    # `step ca certificate` pour les certificats serveurs des conteneurs).
    if [[ "$MODE" == "shared" ]] && id "$SVC_USER" >/dev/null 2>&1; then
      run runuser -u "$SVC_USER" -- step ca bootstrap \
        --ca-url "$CA_URL" --fingerprint "$CA_FINGERPRINT" --force \
        || warn "Bootstrap step-ca pour $SVC_USER en échec (non bloquant)."
    fi
  else
    trust_ca_certificate "$CA_ROOT_FILE"
  fi
}

configure_sshd_stepca() {
  (( CONFIGURE_SSHD )) || return 0
  command -v step >/dev/null 2>&1 || die "step-cli requis pour --configure-sshd"

  log "Confiance sshd envers la CA SSH utilisateur de step-ca"
  local roots=/etc/ssh/step_user_ca_keys.pub tmp
  tmp="$(mktemp)"
  if ! step ssh config --roots > "$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    warn "Aucune racine SSH publiée par step-ca (provisionneur SSH activé ?) : sshd inchangé."
    return 0
  fi
  run install -m 0644 "$tmp" "$roots"
  rm -f "$tmp"

  run install -d -m 0755 /etc/ssh/sshd_config.d
  run install -m 0644 /dev/stdin /etc/ssh/sshd_config.d/60-step-ca.conf <<EOF
# Généré par install-docker-rootless-ubuntu.sh
# Ajout *additif* : les certificats SSH éphémères signés par step-ca sont
# acceptés. Les clés publiques et mots de passe existants restent valables.
TrustedUserCAKeys ${roots}
EOF

  if run sshd -t; then
    run systemctl reload ssh 2>/dev/null || run systemctl reload sshd 2>/dev/null || \
      warn "Rechargement de sshd à faire manuellement."
    ok "sshd accepte les certificats utilisateur step-ca"
  else
    run rm -f /etc/ssh/sshd_config.d/60-step-ca.conf
    die "Configuration sshd invalide : modification annulée."
  fi
}

# --- 5. Allocation subuid/subgid (partagée avec le helper per-user) --------
alloc_subid() {
  local user="$1"
  if grep -q "^${user}:" /etc/subuid && grep -q "^${user}:" /etc/subgid; then
    return 0
  fi
  local start
  start="$(awk -F: -v base="$SUBID_BASE" -v size="$SUBID_SIZE" '
      { e = $2 + $3; if (e > max) max = e }
      END { print (max > base ? int((max + size - 1) / size) * size : base) }
    ' /etc/subuid /etc/subgid 2>/dev/null)"
  [[ -n "$start" ]] || start="$SUBID_BASE"
  grep -q "^${user}:" /etc/subuid || \
    run sh -c "printf '%s:%s:%s\n' '$user' '$start' '$SUBID_SIZE' >> /etc/subuid"
  grep -q "^${user}:" /etc/subgid || \
    run sh -c "printf '%s:%s:%s\n' '$user' '$start' '$SUBID_SIZE' >> /etc/subgid"
  ok "Plage subuid/subgid ${start}+${SUBID_SIZE} attribuée à $user"
}

wait_runtime_dir() {
  local uid="$1" i
  for i in $(seq 1 30); do
    if [[ -d "/run/user/${uid}" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# --- 6. Mode partagé : compte de service + socket de groupe ----------------
setup_service_account() {
  log "Compte de service $SVC_USER et groupe $ACCESS_GROUP"
  getent group "$ACCESS_GROUP" >/dev/null || run groupadd --system "$ACCESS_GROUP"

  if ! id "$SVC_USER" >/dev/null 2>&1; then
    # Groupe primaire = groupe d'accès : la socket créée en 0660 par dockerd
    # est alors lisible par toutes les identités (même temporaires) du groupe.
    run useradd --system --create-home --home-dir "/var/lib/${SVC_USER}" \
      --shell /usr/sbin/nologin --gid "$ACCESS_GROUP" "$SVC_USER"
  fi
  alloc_subid "$SVC_USER"

  run loginctl enable-linger "$SVC_USER"
  local uid; uid="$(id -u "$SVC_USER" 2>/dev/null || echo 0)"
  if (( DRY_RUN == 0 )); then
    wait_runtime_dir "$uid" || die "/run/user/${uid} absent : logind n'a pas ouvert la session de $SVC_USER."
  fi
  ok "Session systemd persistante active pour $SVC_USER (uid $uid)"
}

setup_shared_socket() {
  local uid; uid="$(id -u "$SVC_USER" 2>/dev/null || echo 0)"

  log "Installation du démon rootless pour $SVC_USER"
  run install -m 0644 /dev/stdin /etc/tmpfiles.d/docker-rootless.conf <<EOF
d ${SOCKET_DIR} 0750 ${SVC_USER} ${ACCESS_GROUP} -
EOF
  run systemd-tmpfiles --create /etc/tmpfiles.d/docker-rootless.conf

  run runuser -u "$SVC_USER" -- env \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    PATH=/usr/bin:/usr/sbin:/bin:/sbin \
    dockerd-rootless-setuptool.sh install --force

  # Seconde socket, dans un répertoire accessible au groupe : c'est elle que
  # consomment les identités temporaires.
  local dropin="/var/lib/${SVC_USER}/.config/systemd/user/docker.service.d"
  run install -d -o "$SVC_USER" -g "$ACCESS_GROUP" -m 0755 "$dropin"
  run install -o "$SVC_USER" -g "$ACCESS_GROUP" -m 0644 /dev/stdin \
    "${dropin}/10-shared-socket.conf" <<EOF
[Service]
Environment="DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=${PORT_DRIVER}"
ExecStart=
ExecStart=/usr/bin/dockerd-rootless.sh --host=unix://%t/docker.sock --host=unix://${SOCKET_DIR}/docker.sock --group=${ACCESS_GROUP}
EOF

  run runuser -u "$SVC_USER" -- env \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    sh -c 'systemctl --user daemon-reload && systemctl --user enable --now docker.service && systemctl --user restart docker.service'
  ok "Démon rootless en écoute sur ${SOCKET_DIR}/docker.sock (groupe ${ACCESS_GROUP})"
}

# --- 7. Mode per-user : helper de provisionnement à la volée ---------------
install_provisioner() {
  log "Helper de provisionnement des identités temporaires"
  getent group "$ACCESS_GROUP" >/dev/null || run groupadd --system "$ACCESS_GROUP"
  run install -d -m 0755 "$DATA_ROOT_BASE"

  run install -m 0755 /dev/stdin /usr/local/sbin/docker-rootless-provision-user <<PROV_EOF
#!/usr/bin/env bash
# Provisionne le démon Docker rootless de l'utilisateur appelant.
# Exécuté en root via sudo par les membres du groupe ${ACCESS_GROUP}.
# N'accepte aucun argument et n'agit que sur \$SUDO_USER : conçu pour des
# comptes éphémères (step-ca) dont le HOME peut disparaître à la déconnexion.
set -Eeuo pipefail

SUBID_BASE=${SUBID_BASE}
SUBID_SIZE=${SUBID_SIZE}
DATA_ROOT_BASE="${DATA_ROOT_BASE}"
ACCESS_GROUP="${ACCESS_GROUP}"

(( \$# == 0 )) || { echo "Ce helper n'accepte aucun argument." >&2; exit 2; }
(( EUID == 0 )) || { echo "Doit être exécuté en root (sudo)." >&2; exit 1; }

user="\${SUDO_USER:-}"
[[ -n "\$user" && "\$user" != "root" ]] || { echo "SUDO_USER absent ou root." >&2; exit 1; }
id "\$user" >/dev/null 2>&1 || { echo "Utilisateur inconnu : \$user" >&2; exit 1; }
id -nG "\$user" | tr ' ' '\n' | grep -qx "\$ACCESS_GROUP" || {
  echo "\$user n'appartient pas au groupe \$ACCESS_GROUP." >&2; exit 1; }

uid="\$(id -u "\$user")"
gid="\$(id -g "\$user")"
data_root="\${DATA_ROOT_BASE}/\${user}"
marker="\${data_root}/.provisioned"
if [[ -e "\$marker" ]]; then exit 0; fi

# 1. Plages subuid/subgid (verrou : plusieurs connexions simultanées possibles)
exec 9>/run/lock/docker-rootless-subid.lock
flock 9
if ! grep -q "^\${user}:" /etc/subuid || ! grep -q "^\${user}:" /etc/subgid; then
  start="\$(awk -F: -v base="\$SUBID_BASE" -v size="\$SUBID_SIZE" '
      { e = \$2 + \$3; if (e > max) max = e }
      END { print (max > base ? int((max + size - 1) / size) * size : base) }
    ' /etc/subuid /etc/subgid 2>/dev/null)"
  [[ -n "\$start" ]] || start="\$SUBID_BASE"
  grep -q "^\${user}:" /etc/subuid || printf '%s:%s:%s\n' "\$user" "\$start" "\$SUBID_SIZE" >> /etc/subuid
  grep -q "^\${user}:" /etc/subgid || printf '%s:%s:%s\n' "\$user" "\$start" "\$SUBID_SIZE" >> /etc/subgid
fi
flock -u 9

# 2. Stockage persistant hors du HOME (HOME potentiellement volatile)
install -d -o "\$uid" -g "\$gid" -m 0700 "\$data_root"

# 3. Session systemd persistante puis installation du démon utilisateur
loginctl enable-linger "\$user"
for _ in \$(seq 1 30); do [[ -d "/run/user/\${uid}" ]] && break; sleep 1; done
[[ -d "/run/user/\${uid}" ]] || { echo "/run/user/\${uid} absent." >&2; exit 1; }

runuser -u "\$user" -- env \
  XDG_RUNTIME_DIR="/run/user/\${uid}" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\${uid}/bus" \
  PATH=/usr/bin:/usr/sbin:/bin:/sbin \
  dockerd-rootless-setuptool.sh install --force

runuser -u "\$user" -- env \
  XDG_RUNTIME_DIR="/run/user/\${uid}" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\${uid}/bus" \
  sh -c 'systemctl --user daemon-reload && systemctl --user enable --now docker.service'

touch "\$marker"
echo "Docker rootless prêt pour \$user (data-root : \$data_root)"
PROV_EOF

  # Le data-root est imposé au niveau système : il survit à un HOME éphémère.
  run install -d -m 0755 /etc/systemd/user/docker.service.d
  run install -m 0644 /dev/stdin /etc/systemd/user/docker.service.d/10-data-root.conf <<EOF
[Service]
Environment="DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=${PORT_DRIVER}"
ExecStart=
ExecStart=/usr/bin/dockerd-rootless.sh --data-root=${DATA_ROOT_BASE}/%u
EOF

  run install -m 0440 /dev/stdin /etc/sudoers.d/docker-rootless <<EOF
# Provisionnement du démon Docker rootless des identités temporaires.
%${ACCESS_GROUP} ALL=(root) NOPASSWD: /usr/local/sbin/docker-rootless-provision-user
EOF
  if ! run visudo -cf /etc/sudoers.d/docker-rootless >/dev/null; then
    run rm -f /etc/sudoers.d/docker-rootless
    die "Règle sudoers invalide : annulée."
  fi
  ok "Helper /usr/local/sbin/docker-rootless-provision-user en place"
}

# --- 8. Environnement des clients (identités temporaires incluses) ---------
install_client_env() {
  log "Profil shell : DOCKER_HOST des membres de $ACCESS_GROUP"
  if [[ "$MODE" == "shared" ]]; then
    run install -m 0644 /dev/stdin /etc/profile.d/docker-rootless.sh <<EOF
# Docker rootless — socket partagée (généré, ne pas éditer à la main).
if [ -S "${SOCKET_DIR}/docker.sock" ] && id -nG 2>/dev/null | tr ' ' '\n' | grep -qx "${ACCESS_GROUP}"; then
  DOCKER_HOST="unix://${SOCKET_DIR}/docker.sock"
  export DOCKER_HOST
fi
EOF
  else
    run install -m 0644 /dev/stdin /etc/profile.d/docker-rootless.sh <<EOF
# Docker rootless — un démon par utilisateur (généré, ne pas éditer à la main).
if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx "${ACCESS_GROUP}"; then
  if [ ! -e "${DATA_ROOT_BASE}/\$(id -un)/.provisioned" ]; then
    sudo -n /usr/local/sbin/docker-rootless-provision-user >/dev/null 2>&1 || \
      echo "Docker rootless : provisionnement à lancer avec 'sudo /usr/local/sbin/docker-rootless-provision-user'" >&2
  fi
  if [ -n "\${XDG_RUNTIME_DIR:-}" ] && [ -S "\${XDG_RUNTIME_DIR}/docker.sock" ]; then
    DOCKER_HOST="unix://\${XDG_RUNTIME_DIR}/docker.sock"
    export DOCKER_HOST
  fi
fi
EOF
  fi
  ok "/etc/profile.d/docker-rootless.sh installé"
}

# --- 9. Vérifications ------------------------------------------------------
verify() {
  if (( DRY_RUN )); then return 0; fi
  log "Vérifications"
  docker --version || warn "docker CLI indisponible"
  docker compose version || warn "plugin Compose v2 indisponible"

  if [[ "$MODE" == "shared" ]]; then
    local uid; uid="$(id -u "$SVC_USER")"
    if runuser -u "$SVC_USER" -- env XDG_RUNTIME_DIR="/run/user/${uid}" \
         DOCKER_HOST="unix:///run/user/${uid}/docker.sock" docker info >/dev/null 2>&1; then
      ok "Démon rootless opérationnel"
    else
      warn "Le démon rootless ne répond pas : journalctl --user-unit docker -M ${SVC_USER}@"
    fi
    [[ -S "${SOCKET_DIR}/docker.sock" ]] \
      && ok "Socket partagée : ${SOCKET_DIR}/docker.sock" \
      || warn "Socket partagée absente (relancer : systemctl --user restart docker en tant que $SVC_USER)"
  fi
}

summary() {
  cat <<EOF

$(printf '%s' "$C_OK")Installation terminée.$(printf '%s' "$C_OFF")

Mode ...................... ${MODE}
Groupe d'accès ............ ${ACCESS_GROUP}
EOF
  if [[ "$MODE" == "shared" ]]; then
    cat <<EOF
Compte de service ......... ${SVC_USER}
DOCKER_HOST ............... unix://${SOCKET_DIR}/docker.sock

Ajouter une identité (y compris temporaire) au groupe :
    sudo usermod -aG ${ACCESS_GROUP} <utilisateur>
Pour des comptes éphémères step-ca, faites porter l'appartenance au groupe par
votre annuaire / provisionneur plutôt que par /etc/group.

Déployer Vaultwarden avec ce démon (membre du groupe, DOCKER_HOST déjà exporté
par /etc/profile.d/docker-rootless.sh — reconnexion nécessaire) :
    cd /srv/vaultwarden && docker compose up -d
EOF
  else
    cat <<EOF
Data-root par utilisateur . ${DATA_ROOT_BASE}/<utilisateur>

À la première connexion d'une identité membre de ${ACCESS_GROUP}, le démon est
provisionné automatiquement (ou manuellement) :
    sudo /usr/local/sbin/docker-rootless-provision-user
EOF
  fi
  cat <<EOF

Ports : liaison possible à partir du port ${UNPRIV_PORT_START} sans privilège.
Pilote de port RootlessKit : ${PORT_DRIVER}.
Documentation détaillée : docs/docker-rootless-stepca.md
EOF
}

main() {
  parse_args "$@"
  preflight
  install_prerequisites
  configure_kernel
  install_docker
  configure_apparmor
  disable_rootful_daemon
  if [[ "$MODE" == "shared" ]]; then
    setup_service_account
    setup_shared_socket
  else
    install_provisioner
  fi
  bootstrap_stepca
  configure_sshd_stepca
  install_client_env
  verify
  summary
}

main "$@"
