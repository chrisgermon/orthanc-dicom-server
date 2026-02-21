#!/bin/bash
# ============================================================
# Crowd Image Management - Fresh Ubuntu Install Script
# Installs Docker, clones the project, generates certs,
# sets credentials, and starts the stack.
# ============================================================
set -euo pipefail

INSTALL_DIR="/opt/crowd-image"
REPO_URL=""  # Set if using git clone, otherwise files are copied in place

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
echo -e "${CYAN}  Crowd Image Management - Server Install${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo ""

# ── 1. System updates & prerequisites ──
info "Updating system packages..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release apache2-utils openssl > /dev/null 2>&1
ok "System packages updated."

# ── 2. Install Docker ──
if command -v docker &> /dev/null; then
  ok "Docker already installed: $(docker --version)"
else
  info "Installing Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1
  systemctl enable docker
  systemctl start docker
  ok "Docker installed: $(docker --version)"
fi

# ── 3. Create install directory ──
if [ -d "${INSTALL_DIR}" ]; then
  warn "Install directory ${INSTALL_DIR} already exists."
  read -p "Overwrite config files? Volumes will be preserved. (y/N) " -r
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    err "Aborted."
    exit 1
  fi
fi

mkdir -p "${INSTALL_DIR}"

# ── 4. Copy project files ──
info "Setting up project files in ${INSTALL_DIR}..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Copy all project files
cp -r "${PROJECT_DIR}/config" "${INSTALL_DIR}/"
cp -r "${PROJECT_DIR}/dashboard" "${INSTALL_DIR}/"
cp -r "${PROJECT_DIR}/nginx" "${INSTALL_DIR}/"
cp -r "${PROJECT_DIR}/scripts" "${INSTALL_DIR}/"
cp "${PROJECT_DIR}/docker-compose.yml" "${INSTALL_DIR}/"
cp "${PROJECT_DIR}/.env.example" "${INSTALL_DIR}/"
mkdir -p "${INSTALL_DIR}/certs"
ok "Project files copied."

# ── 5. Generate SSL certificates ──
if [ -f "${INSTALL_DIR}/certs/server.crt" ] && [ -f "${INSTALL_DIR}/certs/server.key" ]; then
  ok "SSL certificates already exist, keeping them."
else
  info "Generating self-signed SSL certificate..."
  openssl req -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -keyout "${INSTALL_DIR}/certs/server.key" \
    -out "${INSTALL_DIR}/certs/server.crt" \
    -subj "/C=AU/ST=NSW/L=Sydney/O=Crowd Image Management/OU=DICOM/CN=$(hostname -f 2>/dev/null || echo 'crowd-image.local')" \
    -addext "subjectAltName=DNS:localhost,DNS:$(hostname -f 2>/dev/null || echo 'crowd-image.local'),IP:127.0.0.1" \
    2>/dev/null
  chmod 600 "${INSTALL_DIR}/certs/server.key"
  chmod 644 "${INSTALL_DIR}/certs/server.crt"
  ok "SSL certificates generated (valid 10 years)."
fi

# ── 6. Set admin credentials ──
echo ""
info "Setting admin credentials for the web interface..."
read -p "  Admin username [admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-admin}"

while true; do
  read -s -p "  Admin password: " ADMIN_PASS
  echo ""
  if [ -z "${ADMIN_PASS}" ]; then
    warn "Password cannot be empty."
    continue
  fi
  read -s -p "  Confirm password: " ADMIN_PASS2
  echo ""
  if [ "${ADMIN_PASS}" != "${ADMIN_PASS2}" ]; then
    warn "Passwords do not match. Try again."
    continue
  fi
  break
done

htpasswd -cb "${INSTALL_DIR}/nginx/.htpasswd" "${ADMIN_USER}" "${ADMIN_PASS}"
ok "Admin credentials set for user '${ADMIN_USER}'."

# ── 7. Set PostgreSQL password ──
echo ""
PG_PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
cat > "${INSTALL_DIR}/.env" <<EOF
# PostgreSQL password - auto-generated during install
POSTGRES_PASSWORD=${PG_PASS}
EOF

# Also update orthanc.json to match
sed -i "s/\"Password\": \"orthanc-secure-change-me\"/\"Password\": \"${PG_PASS}\"/" "${INSTALL_DIR}/config/orthanc.json"
ok "PostgreSQL password generated and configured."

# ── 8. Ensure writable config files exist ──
info "Ensuring config files are writable..."
touch "${INSTALL_DIR}/config/routing-rules.json"
touch "${INSTALL_DIR}/config/routing-log.json"
touch "${INSTALL_DIR}/config/storage-settings.json"

# Set defaults if empty
[ ! -s "${INSTALL_DIR}/config/routing-rules.json" ] && echo '[]' > "${INSTALL_DIR}/config/routing-rules.json"
[ ! -s "${INSTALL_DIR}/config/routing-log.json" ] && echo '[]' > "${INSTALL_DIR}/config/routing-log.json"
[ ! -s "${INSTALL_DIR}/config/storage-settings.json" ] && echo '{"watermarkPercent": 80}' > "${INSTALL_DIR}/config/storage-settings.json"
ok "Config files ready."

# ── 9. Set permissions ──
chmod 600 "${INSTALL_DIR}/.env"
chmod 600 "${INSTALL_DIR}/nginx/.htpasswd"
chmod +x "${INSTALL_DIR}/scripts/"*.sh
ok "Permissions set."

# ── 10. Open firewall ports ──
if command -v ufw &> /dev/null; then
  info "Configuring firewall (ufw)..."
  ufw allow 80/tcp > /dev/null 2>&1 || true
  ufw allow 443/tcp > /dev/null 2>&1 || true
  ufw allow 11112/tcp > /dev/null 2>&1 || true
  ok "Firewall rules added (80, 443, 11112)."
fi

# ── 11. Pull images and start ──
echo ""
info "Pulling Docker images (this may take a few minutes)..."
cd "${INSTALL_DIR}"
docker compose pull
ok "Docker images pulled."

info "Starting services..."
docker compose up -d
ok "Services started."

# ── 12. Wait for health ──
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
  warn "Orthanc did not respond within 60 seconds. Check logs with: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs orthanc"
fi

# ── Done ──
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Installation Complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Dashboard:    ${CYAN}https://${SERVER_IP}/manage/${NC}"
echo -e "  Admin Panel:  ${CYAN}https://${SERVER_IP}/admin${NC}"
echo -e "  OHIF Viewer:  ${CYAN}https://${SERVER_IP}/viewer${NC}"
echo -e "  DICOM Port:   ${CYAN}${SERVER_IP}:11112${NC} (AET: ORTHANC)"
echo ""
echo -e "  Admin login:  ${YELLOW}${ADMIN_USER}${NC} / (password you set)"
echo -e "  Install dir:  ${INSTALL_DIR}"
echo ""
echo -e "  Manage:       ${CYAN}cd ${INSTALL_DIR} && docker compose logs -f${NC}"
echo -e "  Restart:      ${CYAN}cd ${INSTALL_DIR} && docker compose restart${NC}"
echo -e "  Stop:         ${CYAN}cd ${INSTALL_DIR} && docker compose down${NC}"
echo ""
echo -e "  ${YELLOW}Note: Using self-signed SSL. Your browser will show a security warning.${NC}"
echo ""
