#!/bin/bash
# ---------------------------------------------------------------------------
# Sauvegarde Vaultwarden (Synology)
# À planifier dans DSM : Panneau de configuration > Planificateur de tâches >
# Créer > Tâche planifiée > Script défini par l'utilisateur (exécuter en root).
#
#   bash /volume1/docker/vaultwarden/scripts/backup-vaultwarden.sh
#
# Produit une archive .tar.gz cohérente (copie à chaud de la base SQLite)
# dans $BACKUP_DIR et supprime celles de plus de $RETENTION_DAYS jours.
# ---------------------------------------------------------------------------
set -euo pipefail

DATA_PATH="${DATA_PATH:-/volume1/docker/vaultwarden/data}"
BACKUP_DIR="${BACKUP_DIR:-/volume1/docker/vaultwarden/backups}"
CONTAINER="${CONTAINER:-vaultwarden}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"

STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { echo "[$(date '+%F %T')] $*"; }

[ -d "$DATA_PATH" ] || { log "ERREUR : $DATA_PATH introuvable"; exit 1; }
mkdir -p "$BACKUP_DIR"

# --- 1. Base SQLite : copie à chaud si sqlite3 est disponible, sinon arrêt bref
STOPPED=0
if command -v sqlite3 >/dev/null 2>&1; then
  log "Copie à chaud de la base (sqlite3 .backup)"
  sqlite3 "$DATA_PATH/db.sqlite3" ".backup '$WORK/db.sqlite3'"
else
  log "sqlite3 absent : arrêt temporaire du conteneur $CONTAINER"
  docker stop "$CONTAINER" >/dev/null
  STOPPED=1
  cp -a "$DATA_PATH/db.sqlite3" "$WORK/db.sqlite3"
fi

# --- 2. Reste des données (clés, pièces jointes, Sends, configuration)
for item in rsa_key.pem rsa_key.pub.pem rsa_key.der rsa_key.pub.der private_rsa_key.pem \
            config.json attachments sends icon_cache; do
  [ -e "$DATA_PATH/$item" ] && cp -a "$DATA_PATH/$item" "$WORK/" || true
done

# --- 3. Fichiers de déploiement (compose + .env) s'ils sont à côté des données
PROJECT_DIR="$(dirname "$DATA_PATH")"
for f in docker-compose.yml .env; do
  [ -f "$PROJECT_DIR/$f" ] && cp -a "$PROJECT_DIR/$f" "$WORK/" || true
done

if [ "$STOPPED" -eq 1 ]; then
  docker start "$CONTAINER" >/dev/null
  log "Conteneur $CONTAINER redémarré"
fi

# --- 4. Archive
ARCHIVE="$BACKUP_DIR/vaultwarden-$STAMP.tar.gz"
tar -czf "$ARCHIVE" -C "$WORK" .
chmod 600 "$ARCHIVE"
log "Sauvegarde créée : $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"

# --- 5. Rotation
find "$BACKUP_DIR" -name 'vaultwarden-*.tar.gz' -mtime "+$RETENTION_DAYS" -print -delete \
  | sed 's/^/[purge] /' || true

log "Terminé."
