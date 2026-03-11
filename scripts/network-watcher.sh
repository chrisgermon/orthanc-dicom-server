#!/bin/bash
# ============================================================
# Crowd Image Management - Network Configuration Watcher
# Runs on the host as a systemd service.
# Polls pending-network-config.json for changes, validates,
# generates netplan YAML, and applies via netplan try.
# Results are written to network-status.json.
# ============================================================
set -uo pipefail

INSTALL_DIR="/opt/crowd-image"
PENDING_FILE="${INSTALL_DIR}/config/pending-network-config.json"
STATUS_FILE="${INSTALL_DIR}/config/network-status.json"
NETPLAN_FILE="/etc/netplan/01-crowd-dhcp.yaml"
POLL_INTERVAL=2

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

# ── Gather current interface info and write to status file ──
update_status() {
  local apply_status="${1:-}"
  local apply_message="${2:-}"

  local interfaces_json="["
  local first=true

  for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|veth|br-|virbr)'); do
    # Validate interface name
    if ! echo "$iface" | grep -qE '^[a-zA-Z0-9._-]{1,15}$'; then
      continue
    fi

    local mac
    mac=$(ip link show "$iface" 2>/dev/null | awk '/ether/ {print $2}')
    local state
    state=$(ip link show "$iface" 2>/dev/null | grep -oP 'state \K\w+')
    local ipv4
    ipv4=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)

    # Detect if DHCP or static from current netplan
    local method="unknown"
    if [ -f "$NETPLAN_FILE" ]; then
      if grep -A2 "^    ${iface}:" "$NETPLAN_FILE" 2>/dev/null | grep -q "dhcp4: true"; then
        method="dhcp"
      else
        method="static"
      fi
    fi

    # Get gateway (default route via this interface)
    local gateway
    gateway=$(ip route show default dev "$iface" 2>/dev/null | awk '{print $3}' | head -1)

    # Get DNS from systemd-resolved or resolv.conf
    local dns=""
    if command -v resolvectl &>/dev/null; then
      dns=$(resolvectl dns "$iface" 2>/dev/null | grep -oP '[\d.]+' | head -2 | tr '\n' ',' | sed 's/,$//')
    fi
    if [ -z "$dns" ] && [ -f /etc/resolv.conf ]; then
      dns=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | head -2 | tr '\n' ',' | sed 's/,$//')
    fi

    if [ "$first" = true ]; then
      first=false
    else
      interfaces_json+=","
    fi

    interfaces_json+=$(cat <<IEOF
{
      "name": "${iface}",
      "mac": "${mac:-unknown}",
      "state": "${state:-unknown}",
      "ip": "${ipv4:-none}",
      "method": "${method}",
      "gateway": "${gateway:-}",
      "dns": "${dns:-}"
    }
IEOF
)
  done
  interfaces_json+="]"

  # Build status JSON
  local status_json="{"
  status_json+="\"interfaces\": ${interfaces_json}"
  status_json+=", \"updated\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\""
  if [ -n "$apply_status" ]; then
    status_json+=", \"applyStatus\": \"${apply_status}\""
    status_json+=", \"applyMessage\": \"${apply_message}\""
  fi
  status_json+="}"

  echo "$status_json" > "${STATUS_FILE}.tmp"
  mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

# ── Validate config with Python ──
validate_config() {
  local config="$1"
  python3 -c "
import json, sys, ipaddress, re

try:
    data = json.loads(sys.stdin.read())
except json.JSONDecodeError as e:
    print(f'Invalid JSON: {e}', file=sys.stderr)
    sys.exit(1)

if not isinstance(data, dict) or 'interfaces' not in data:
    print('Missing interfaces key', file=sys.stderr)
    sys.exit(1)

for iface_name, cfg in data['interfaces'].items():
    # Validate interface name
    if not re.match(r'^[a-zA-Z0-9._-]{1,15}$', iface_name):
        print(f'Invalid interface name: {iface_name}', file=sys.stderr)
        sys.exit(1)

    method = cfg.get('method', '')
    if method not in ('dhcp', 'static'):
        print(f'Invalid method for {iface_name}: {method}', file=sys.stderr)
        sys.exit(1)

    if method == 'static':
        # Validate IP/CIDR
        ip_cidr = cfg.get('address', '')
        try:
            ipaddress.ip_interface(ip_cidr)
        except ValueError:
            print(f'Invalid address for {iface_name}: {ip_cidr}', file=sys.stderr)
            sys.exit(1)

        # Validate gateway if provided
        gw = cfg.get('gateway', '')
        if gw:
            try:
                ipaddress.ip_address(gw)
            except ValueError:
                print(f'Invalid gateway for {iface_name}: {gw}', file=sys.stderr)
                sys.exit(1)

        # Validate DNS if provided
        dns_list = cfg.get('dns', [])
        if isinstance(dns_list, str):
            dns_list = [d.strip() for d in dns_list.split(',') if d.strip()]
        for dns in dns_list:
            try:
                ipaddress.ip_address(dns)
            except ValueError:
                print(f'Invalid DNS for {iface_name}: {dns}', file=sys.stderr)
                sys.exit(1)

print('OK')
" <<< "$config"
}

# ── Generate netplan YAML from config ──
generate_netplan() {
  local config="$1"
  python3 -c "
import json, sys

data = json.loads(sys.stdin.read())
lines = [
    '# Generated by Crowd Image Management network watcher',
    'network:',
    '  version: 2',
    '  renderer: networkd',
    '  ethernets:',
]

for iface_name, cfg in data['interfaces'].items():
    method = cfg.get('method', 'dhcp')
    lines.append(f'    {iface_name}:')

    if method == 'dhcp':
        lines.append('      dhcp4: true')
        lines.append('      dhcp6: true')
    else:
        lines.append('      dhcp4: false')
        lines.append('      dhcp6: false')
        address = cfg.get('address', '')
        if address:
            lines.append(f'      addresses: [{address}]')
        gw = cfg.get('gateway', '')
        if gw:
            lines.append('      routes:')
            lines.append(f'        - to: default')
            lines.append(f'          via: {gw}')
        dns_list = cfg.get('dns', [])
        if isinstance(dns_list, str):
            dns_list = [d.strip() for d in dns_list.split(',') if d.strip()]
        if dns_list:
            dns_str = ', '.join(dns_list)
            lines.append('      nameservers:')
            lines.append(f'        addresses: [{dns_str}]')

print('\n'.join(lines))
" <<< "$config"
}

# ── Apply pending network configuration ──
apply_config() {
  local config
  config=$(cat "$PENDING_FILE")

  # Skip empty or no-op config
  if [ -z "$config" ] || [ "$config" = "{}" ]; then
    return 1
  fi

  log "Pending network config detected, validating..."

  # Validate
  local validation
  validation=$(validate_config "$config" 2>&1)
  if [ $? -ne 0 ]; then
    log "Validation failed: $validation"
    update_status "failed" "Validation error: $validation"
    echo '{}' > "$PENDING_FILE"
    return 1
  fi

  log "Validation passed, generating netplan..."

  # Backup current netplan
  if [ -f "$NETPLAN_FILE" ]; then
    cp "$NETPLAN_FILE" "${NETPLAN_FILE}.bak.$(date +%s)"
  fi

  # Generate new netplan
  local netplan_yaml
  netplan_yaml=$(generate_netplan "$config" 2>&1)
  if [ $? -ne 0 ]; then
    log "Netplan generation failed: $netplan_yaml"
    update_status "failed" "Failed to generate netplan config"
    echo '{}' > "$PENDING_FILE"
    return 1
  fi

  echo "$netplan_yaml" > "$NETPLAN_FILE"
  chmod 600 "$NETPLAN_FILE"

  log "Netplan written, applying with 60s timeout (auto-rollback if connectivity lost)..."
  update_status "applying" "Applying network configuration..."

  # Apply with auto-rollback
  local apply_output
  apply_output=$(netplan try --timeout 60 2>&1)
  local apply_rc=$?

  if [ $apply_rc -eq 0 ]; then
    log "Network configuration applied successfully"
    # Wait briefly for network to settle
    sleep 3
    update_status "applied" "Configuration applied successfully"
  else
    log "netplan try failed (rc=$apply_rc): $apply_output"
    # Restore backup if available
    local latest_bak
    latest_bak=$(ls -t "${NETPLAN_FILE}".bak.* 2>/dev/null | head -1)
    if [ -n "$latest_bak" ]; then
      cp "$latest_bak" "$NETPLAN_FILE"
      netplan apply 2>/dev/null || true
    fi
    update_status "rolled_back" "Configuration rolled back: $apply_output"
  fi

  # Clear pending file
  echo '{}' > "$PENDING_FILE"
  log "Pending config cleared"
}

# ── Main loop ──
log "Network watcher started (polling every ${POLL_INTERVAL}s)"
log "Pending file: $PENDING_FILE"
log "Status file: $STATUS_FILE"

# Write initial status
update_status

LAST_HASH=""
TICK=0

while true; do
  sleep "$POLL_INTERVAL"

  # Check if pending file has meaningful content
  if [ ! -f "$PENDING_FILE" ]; then
    continue
  fi

  CURRENT_HASH=$(md5sum "$PENDING_FILE" 2>/dev/null | awk '{print $1}')
  EMPTY_HASH=$(echo -n '{}' | md5sum | awk '{print $1}')

  # Skip if unchanged or empty
  if [ "$CURRENT_HASH" = "$LAST_HASH" ] || [ "$CURRENT_HASH" = "$EMPTY_HASH" ]; then
    # Still update status periodically (every 30 seconds worth of polls)
    TICK=$(( (TICK + 1) % 15 ))
    if [ "$TICK" -eq 0 ]; then
      update_status
    fi
    continue
  fi

  LAST_HASH="$CURRENT_HASH"
  apply_config

  # Update status after apply
  sleep 2
  update_status
done
