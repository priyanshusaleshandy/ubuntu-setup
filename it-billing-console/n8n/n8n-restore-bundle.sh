#!/bin/bash
# Builds a SELF-SUFFICIENT n8n restore bundle and ships it to the NAS.
#
# The point of this bundle, and the reason it is not just a workflow export:
# restoring it must bring n8n back with every credential already working, with
# nothing to re-authorise. That needs three things together -
#   database.sqlite  workflows + credentials (credentials are encrypted)
#   config           the encryption key, without which those credentials are junk
#   .env / compose   how to stand the container up in the first place
# Any one of them missing turns a "2 minute restore" into redoing every OAuth.
#
# Runs every 4h from the n8n workflow n8nBundle4h. Safe to run by hand.
set -euo pipefail

D=/usr/local/bin/docker
NAS_HOST="truenas_admin@192.168.126.21"
NAS_DIR="/mnt/ikigai-local/share1/Backups/IKI-MAC-27/n8n-4h"
KEEP=2   # newest 2, not 1: a corrupt run must never be able to destroy the only copy
STAGE=/Users/admin/backup-staging/n8n-bundle

TS=$(date +%Y%m%d-%H%M)
ZIP="n8n-restore-$TS.zip"

rm -rf "$STAGE"
mkdir -p "$STAGE/bundle"

# A live SQLite file must never be copied byte-for-byte - the -wal can hold rows
# the main file has not seen yet (this exact trap already bit biomax.db). VACUUM
# INTO is an online snapshot and needs no downtime.
$D exec n8n sh -c 'cd /usr/local/lib/node_modules/n8n && rm -f /home/node/snap.sqlite && node -e "
const s = require(\"sqlite3\");
const db = new s.Database(\"/home/node/.n8n/database.sqlite\");
db.run(\"VACUUM INTO \x27/home/node/snap.sqlite\x27\", e => { if (e) { console.error(e.message); process.exit(1); } });
"' || { echo "ERROR sqlite snapshot failed"; exit 1; }

$D exec n8n cat /home/node/snap.sqlite > "$STAGE/bundle/database.sqlite"
$D exec n8n rm -f /home/node/snap.sqlite
$D exec n8n cat /home/node/.n8n/config > "$STAGE/bundle/config"

cp /Users/admin/n8n/docker-compose.yml "$STAGE/bundle/docker-compose.yml"
cp /Users/admin/n8n/.env              "$STAGE/bundle/.env"

# Logical exports too: if the sqlite file itself is ever the problem, these still
# import into a fresh n8n.
$D exec n8n n8n export:workflow --all --output=/home/node/wf.json >/dev/null 2>&1 \
  && $D exec n8n cat /home/node/wf.json > "$STAGE/bundle/workflows.json" \
  && $D exec n8n rm -f /home/node/wf.json \
  || echo "WARN logical workflow export failed"

cat > "$STAGE/bundle/RESTORE.txt" <<'TXT'
Restore n8n from this bundle
============================
Everything needed is in here - no credential has to be re-authorised.

  1. mkdir -p ~/n8n && cd ~/n8n
     cp docker-compose.yml .env  ~/n8n/

  2. docker compose up -d          # creates the n8n_n8n_data volume
     docker compose stop

  3. docker cp database.sqlite  n8n:/home/node/.n8n/database.sqlite
     docker cp config           n8n:/home/node/.n8n/config
     docker exec -u root n8n chown node:node /home/node/.n8n/database.sqlite /home/node/.n8n/config

  4. docker compose start

config carries N8N_ENCRYPTION_KEY's twin - the key the stored credentials are
encrypted with. .env carries the same key for the container environment. Restore
both or the credentials import but cannot be decrypted.

workflows.json is a fallback only: `n8n import:workflow --input=workflows.json`
brings the workflows back but NOT the credentials.
TXT

cd "$STAGE"
zip -qr "$ZIP" bundle
SZ=$(du -h "$ZIP" | cut -f1)
LOCAL_SUM=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "OK  built $ZIP ($SZ)"

# Upload, then verify by hash before anything old is removed. Nothing is pruned
# on trust - the same rule the daily job already follows.
ssh -o BatchMode=yes "$NAS_HOST" "mkdir -p '$NAS_DIR'"
scp -o BatchMode=yes -q "$ZIP" "$NAS_HOST:$NAS_DIR/$ZIP"
REMOTE_SUM=$(ssh -o BatchMode=yes "$NAS_HOST" "sha256sum '$NAS_DIR/$ZIP' | cut -d' ' -f1")

if [ "$LOCAL_SUM" != "$REMOTE_SUM" ]; then
  echo "ERROR checksum mismatch after upload - nothing pruned"
  exit 1
fi
echo "OK  verified on NAS ($NAS_DIR/$ZIP)"

PRUNED=$(ssh -o BatchMode=yes "$NAS_HOST" \
  "ls -1t '$NAS_DIR'/n8n-restore-*.zip 2>/dev/null | tail -n +$((KEEP+1)) | tee /dev/stderr | xargs -r rm -f" 2>&1 >/dev/null | grep -c . || true)
KEPT=$(ssh -o BatchMode=yes "$NAS_HOST" "ls -1 '$NAS_DIR'/n8n-restore-*.zip 2>/dev/null | wc -l" | tr -d ' ')

echo "OK  rotation: pruned $PRUNED, kept $KEPT (keep=$KEEP)"
echo "BUNDLE=$STAGE/$ZIP"
echo "BUNDLE_NAME=$ZIP"
echo "BUNDLE_SIZE=$SZ"
echo "---BUNDLE-DONE---"
