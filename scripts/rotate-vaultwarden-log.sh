#!/bin/bash
# ---------------------------------------------------------------------------
# Rotation du journal Vaultwarden (activé par LOG_FILE, lu par fail2ban).
# À planifier une fois par semaine dans le Planificateur de tâches DSM (root) :
#   bash /volume1/docker/vaultwarden/scripts/rotate-vaultwarden-log.sh
#
# Méthode « copytruncate » : le fichier garde le même inode, Vaultwarden n'a
# pas besoin d'être redémarré et fail2ban repart proprement du début.
# ---------------------------------------------------------------------------
set -euo pipefail

DATA_PATH="${DATA_PATH:-/volume1/docker/vaultwarden/data}"
LOG="$DATA_PATH/vaultwarden.log"
MAX_SIZE_MB="${MAX_SIZE_MB:-20}"
KEEP="${KEEP:-4}"

[ -f "$LOG" ] || exit 0

SIZE_MB=$(( $(stat -c %s "$LOG") / 1024 / 1024 ))
[ "$SIZE_MB" -ge "$MAX_SIZE_MB" ] || exit 0

for i in $(seq $((KEEP - 1)) -1 1); do
  [ -f "$LOG.$i.gz" ] && mv "$LOG.$i.gz" "$LOG.$((i + 1)).gz"
done

cp "$LOG" "$LOG.1"
: > "$LOG"
gzip -f "$LOG.1"
rm -f "$LOG.$((KEEP + 1)).gz"

echo "[$(date '+%F %T')] Journal pivoté (${SIZE_MB} Mo) -> $LOG.1.gz"
