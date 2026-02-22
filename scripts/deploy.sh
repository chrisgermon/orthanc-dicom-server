#!/bin/bash
# ============================================================
# Crowd Image Management - Pull & Restart
# Pulls latest code from git and restarts Docker services.
# Run on the server: sudo /opt/crowd-image/scripts/deploy.sh
# ============================================================
set -euo pipefail

INSTALL_DIR="/opt/crowd-image"
REPO_URL="https://github.com/chrisgermon/orthanc-dicom-server.git"
BRANCH="master"

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ── Must run as root ──
if [ "$(id -u)" -ne 0 ]; then
  err "This script must be run as root (sudo)."
  exit 1
fi

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Crowd Image Management - Deploy Update${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo ""

cd "${INSTALL_DIR}"

# ── Initialise git repo if needed ──
if [ ! -d ".git" ]; then
  info "Initialising git repo (first-time setup)..."
  git init
  git remote add origin "${REPO_URL}"
  git fetch origin "${BRANCH}"

  # Stage everything so we can merge without losing local files
  git checkout -b "${BRANCH}"
  git reset --soft "origin/${BRANCH}"
  ok "Git repo initialised."
else
  info "Fetching latest changes from origin/${BRANCH}..."
  git fetch origin "${BRANCH}"
fi

# ── Check for updates ──
LOCAL=$(git rev-parse HEAD 2>/dev/null || echo "none")
REMOTE=$(git rev-parse "origin/${BRANCH}" 2>/dev/null || echo "none")

if [ "${LOCAL}" = "${REMOTE}" ]; then
  ok "Already up to date (${LOCAL:0:7})."
  echo ""
  read -p "  Restart services anyway? (y/N) " -r
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "  Done — no changes."
    exit 0
  fi
else
  info "Update available: ${LOCAL:0:7} → ${REMOTE:0:7}"
  echo ""
  git log --oneline "${LOCAL}..origin/${BRANCH}" 2>/dev/null | head -20 | while read -r line; do
    echo -e "    ${line}"
  done
  echo ""
fi

# ── Preserve local config files that shouldn't be overwritten ──
PRESERVE_FILES=(
  ".env"
  "nginx/.htpasswd"
  "certs/server.crt"
  "certs/server.key"
  "config/orthanc.json"
  "config/routing-rules.json"
  "config/routing-log.json"
  "config/storage-settings.json"
  "config/pending-network-config.json"
  "config/network-status.json"
  "config/server-aetitles.json"
)

info "Backing up local config..."
BACKUP_DIR=$(mktemp -d "/tmp/crowd-deploy-backup.XXXXXX")
for f in "${PRESERVE_FILES[@]}"; do
  if [ -f "${INSTALL_DIR}/${f}" ]; then
    mkdir -p "${BACKUP_DIR}/$(dirname "$f")"
    cp "${INSTALL_DIR}/${f}" "${BACKUP_DIR}/${f}"
  fi
done
ok "Config backed up to ${BACKUP_DIR}"

# ── Pull latest code ──
info "Pulling latest code..."
git reset --hard "origin/${BRANCH}"
ok "Code updated to $(git rev-parse --short HEAD)."

# ── Restore preserved config files ──
info "Restoring local config..."
for f in "${PRESERVE_FILES[@]}"; do
  if [ -f "${BACKUP_DIR}/${f}" ]; then
    mkdir -p "${INSTALL_DIR}/$(dirname "$f")"
    cp "${BACKUP_DIR}/${f}" "${INSTALL_DIR}/${f}"
  fi
done
rm -rf "${BACKUP_DIR}"
ok "Config restored."

# ── Fix permissions ──
chmod +x "${INSTALL_DIR}/scripts/"*.sh 2>/dev/null || true

# ── Sanitize orthanc.json (fix known issues from dashboard saves) ──
info "Sanitizing orthanc.json..."
ORTHANC_CFG="${INSTALL_DIR}/config/orthanc.json"
if [ -f "${ORTHANC_CFG}" ] && command -v python3 &> /dev/null; then
  python3 << 'PYEOF'
import json, sys
cfg_path = "/opt/crowd-image/config/orthanc.json"
try:
    with open(cfg_path) as f:
        c = json.load(f)
    changed = False
    # Fix empty arrays that should be objects
    for key in ["OrthancPeers", "RegisteredUsers"]:
        if key in c and isinstance(c[key], list) and len(c[key]) == 0:
            c[key] = {}
            changed = True
    # Fix string values that should be integers
    int_fields = ["HttpPort", "DicomPort", "ConcurrentJobs", "DicomScuTimeout",
        "JobsHistorySize", "MaximumPatientCount", "MaximumStorageCacheSize",
        "MaximumStorageSize", "MediaArchiveSize", "StableAge", "HttpTimeout"]
    for k in int_fields:
        if k in c and isinstance(c[k], str):
            c[k] = int(c[k])
            changed = True
    if "PostgreSQL" in c and isinstance(c["PostgreSQL"].get("Port"), str):
        c["PostgreSQL"]["Port"] = int(c["PostgreSQL"]["Port"])
        changed = True
    for name, mod in c.get("DicomModalities", {}).items():
        if isinstance(mod, dict) and isinstance(mod.get("Port"), str):
            mod["Port"] = int(mod["Port"])
            changed = True
    if changed:
        with open(cfg_path, "w") as f:
            json.dump(c, f, indent=2)
        print("  Fixed config issues")
    else:
        print("  Config OK")
except Exception as e:
    print(f"  Warning: could not sanitize config: {e}", file=sys.stderr)
PYEOF
fi
ok "Config sanitized."

# ── Restart services ──
info "Pulling Docker images..."
docker compose pull
ok "Images up to date."

info "Restarting services..."
docker compose up -d
ok "Services restarted."

# ── Wait for health ──
info "Waiting for Orthanc to become ready..."
TRIES=0
MAX_TRIES=30
while [ $TRIES -lt $MAX_TRIES ]; do
  if docker compose exec -T orthanc curl -sf http://localhost:8042/system > /dev/null 2>&1; then
    break
  fi
  sleep 2
  TRIES=$((TRIES + 1))
done

if [ $TRIES -lt $MAX_TRIES ]; then
  ok "Orthanc is running and healthy."
else
  warn "Orthanc did not respond within 60 seconds. Check: docker compose logs orthanc"
fi

# ── Done ──
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Deploy Complete — $(git rev-parse --short HEAD)${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
docker compose ps --format "table {{.Name}}\t{{.Status}}"
echo ""
