#!/bin/bash
# ---------------------------------------------------------------------------
# Restauration Vaultwarden (Synology)
#   sudo bash restore-vaultwarden.sh /volume1/docker/vaultwarden/backups/vaultwarden-AAAAMMJJ-HHMMSS.tar.gz
# Le conteneur est arrêté, les données actuelles sont mises de côté
# (data.old-<horodatage>) puis l'archive est déployée.
# ---------------------------------------------------------------------------
set -euo pipefail

ARCHIVE="${1:-}"
DATA_PATH="${DATA_PATH:-/volume1/docker/vaultwarden/data}"
CONTAINER="${CONTAINER:-vaultwarden}"

[ -f "$ARCHIVE" ] || { echo "Usage : $0 <archive.tar.gz>"; exit 1; }

echo "Restauration de $ARCHIVE vers $DATA_PATH"
read -r -p "Confirmer ? (oui/non) " ANSWER
[ "$ANSWER" = "oui" ] || { echo "Annulé."; exit 1; }

docker stop "$CONTAINER" >/dev/null 2>&1 || true

if [ -d "$DATA_PATH" ]; then
  mv "$DATA_PATH" "${DATA_PATH}.old-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$DATA_PATH"
tar -xzf "$ARCHIVE" -C "$DATA_PATH"

# docker-compose.yml / .env éventuellement inclus dans l'archive : on les
# remonte d'un niveau, ils n'ont rien à faire dans /data.
PROJECT_DIR="$(dirname "$DATA_PATH")"
for f in docker-compose.yml .env; do
  [ -f "$DATA_PATH/$f" ] && mv "$DATA_PATH/$f" "$PROJECT_DIR/$f"
done

docker start "$CONTAINER" >/dev/null
echo "Conteneur redémarré. Vérifiez : docker logs --tail 50 $CONTAINER"
