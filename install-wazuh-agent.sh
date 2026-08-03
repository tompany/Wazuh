#!/usr/bin/env bash
set -Eeuo pipefail

# Wazuh Agent one-run installer for Debian/Ubuntu systems
# Usage:
#   sudo bash install-wazuh-agent.sh
#   sudo bash install-wazuh-agent.sh 10.20.20.157 custom-agent-name

MANAGER_IP="${1:-10.20.20.157}"
AGENT_NAME="${2:-$(hostname -s)}"
TIMEZONE="Europe/Amsterdam"
WAZUH_REPO="https://packages.wazuh.com/4.x/apt/"
KEY_URL="https://packages.wazuh.com/key/GPG-KEY-WAZUH"
KEYRING="/usr/share/keyrings/wazuh.gpg"
REPO_FILE="/etc/apt/sources.list.d/wazuh.list"

log() {
    printf '\n\033[1;36m==> %s\033[0m\n' "$*"
}

fail() {
    printf '\n\033[1;31mFOUT: %s\033[0m\n' "$*" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || fail "Voer dit script uit met sudo."
[[ -r /etc/os-release ]] || fail "/etc/os-release ontbreekt."

# shellcheck disable=SC1091
. /etc/os-release

case "${ID:-}" in
    ubuntu|debian) ;;
    *)
        if [[ "${ID_LIKE:-}" != *debian* ]]; then
            fail "Niet-ondersteund besturingssysteem: ${PRETTY_NAME:-onbekend}"
        fi
        ;;
esac

log "Doelconfiguratie"
printf 'Manager:   %s\nAgentnaam: %s\nTijdzone:  %s\nOS:        %s\n' \
    "$MANAGER_IP" "$AGENT_NAME" "$TIMEZONE" "${PRETTY_NAME:-onbekend}"

log "Tijdzone en tijdsynchronisatie instellen"
timedatectl set-timezone "$TIMEZONE"
timedatectl set-ntp true 2>/dev/null || true

log "Benodigde pakketten installeren"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gnupg

log "Wazuh-repository en ondertekeningssleutel configureren"
install -d -m 0755 /usr/share/keyrings
tmp_key="$(mktemp)"
trap 'rm -f "$tmp_key"' EXIT

curl -fsSL "$KEY_URL" -o "$tmp_key"
gpg --batch --yes --dearmor -o "$KEYRING" "$tmp_key"
chmod 0644 "$KEYRING"

cat > "$REPO_FILE" <<EOF
deb [signed-by=$KEYRING] $WAZUH_REPO stable main
EOF
chmod 0644 "$REPO_FILE"

apt-get update

log "Wazuh-agent installeren en aan Sentinel koppelen"
WAZUH_MANAGER="$MANAGER_IP" \
WAZUH_REGISTRATION_SERVER="$MANAGER_IP" \
WAZUH_AGENT_NAME="$AGENT_NAME" \
DEBIAN_FRONTEND=noninteractive \
apt-get install -y wazuh-agent

log "Manageradres in de agentconfiguratie controleren"
if ! grep -q "<address>${MANAGER_IP}</address>" /var/ossec/etc/ossec.conf; then
    fail "Manageradres $MANAGER_IP staat niet correct in /var/ossec/etc/ossec.conf."
fi

log "Wazuh-agent activeren"
systemctl daemon-reload
systemctl enable --now wazuh-agent

sleep 3

if ! systemctl is-active --quiet wazuh-agent; then
    systemctl status wazuh-agent --no-pager -l || true
    fail "De Wazuh-agent is niet actief geworden."
fi

log "Installatie geslaagd"
systemctl status wazuh-agent --no-pager -l
printf '\nAgentconfiguratie:\n'
grep -E '<address>|<server>' /var/ossec/etc/ossec.conf || true
printf '\nControleer op Sentinel met:\n'
printf '  sudo /var/ossec/bin/agent_control -l\n'
