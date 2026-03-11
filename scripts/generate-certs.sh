#!/bin/bash
# Generate self-signed SSL certificates for Crowd Image Management
CERT_DIR="$(cd "$(dirname "$0")/../certs" && pwd)"

if [ -f "${CERT_DIR}/server.crt" ] && [ -f "${CERT_DIR}/server.key" ]; then
  echo "Certificates already exist in ${CERT_DIR}"
  read -p "Regenerate? (y/N) " confirm
  [ "$confirm" != "y" ] && exit 0
fi

echo "Generating self-signed SSL certificate..."

openssl req -x509 -nodes -days 3650 \
  -newkey rsa:2048 \
  -keyout "${CERT_DIR}/server.key" \
  -out "${CERT_DIR}/server.crt" \
  -subj "/C=AU/ST=NSW/L=Sydney/O=Crowd Image Management/OU=DICOM/CN=crowd-image.local" \
  -addext "subjectAltName=DNS:localhost,DNS:crowd-image.local,IP:127.0.0.1"

chmod 600 "${CERT_DIR}/server.key"
chmod 644 "${CERT_DIR}/server.crt"

echo "Certificates generated:"
echo "  ${CERT_DIR}/server.crt"
echo "  ${CERT_DIR}/server.key"
echo ""
echo "Valid for 10 years."
