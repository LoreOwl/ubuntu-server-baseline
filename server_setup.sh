#!/bin/bash
# ==============================================================================
#  Ubuntu 24.04 LTS — Hardened Server Baseline
#  Docker  ·  Portainer CE  ·  Prometheus  ·  Node Exporter  ·  Grafana
#
#  HOW TO USE:
#    1. Fill in every value marked CHANGE_ME in the CONFIGURATION section below
#    2. Copy this file to the server:
#         scp server_setup.sh <user>@<current-ip>:~/
#    3. SSH in and run:
#         chmod +x server_setup.sh && sudo bash server_setup.sh
# ==============================================================================

set -euo pipefail

# Must be run interactively — the SSH verification prompt reads from stdin.
# If piped (curl | bash), the read hits EOF and set -e aborts AFTER password
# auth is disabled, risking lockout.
[[ -t 0 ]] || {
    echo -e "\n\033[0;31m[x] ERROR:\033[0m This script must be run interactively, not piped."
    echo "    Copy it to the server first, then run: sudo bash server_setup.sh"
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
#  CONFIGURATION — Fill in ALL values marked CHANGE_ME before running
# ─────────────────────────────────────────────────────────────────────────────

# ── Network ───────────────────────────────────────────────────────────────────
STATIC_IP="192.168.X.XXX"    # CHANGE_ME  e.g. 192.168.1.100
SUBNET_PREFIX="24"            # 24 = 255.255.255.0 (leave for most home networks)
GATEWAY_IP="192.168.X.X"     # CHANGE_ME  e.g. 192.168.1.1
NET_INTERFACE="CHANGE_ME"     # CHANGE_ME  check your interface: ip link show
                               #            look for eth0, enp3s0, etc.
DNS_SERVERS="1.1.1.1, 8.8.8.8" # Space/comma-separated; change for internal resolvers

# ── New admin OS user ─────────────────────────────────────────────────────────
NEW_USERNAME="CHANGE_ME"      # CHANGE_ME  e.g. serveradmin
NEW_PASSWORD=""               # Prompted at runtime — not stored in this file

# ── Hostname ──────────────────────────────────────────────────────────────────
NEW_HOSTNAME="ubuntu-server"  # Change if desired

# ── SSH Public Key ────────────────────────────────────────────────────────────
# Get yours with: cat ~/.ssh/id_ed25519.pub
# On Windows:     type C:\Users\YourName\.ssh\id_ed25519.pub
SSH_PUBLIC_KEY="PASTE_YOUR_PUBLIC_KEY_HERE"

# ── Portainer admin account ───────────────────────────────────────────────────
PORTAINER_USERNAME="CHANGE_ME"   # CHANGE_ME  e.g. admin
PORTAINER_PASSWORD=""            # Prompted at runtime — not stored in this file

# ── Grafana admin account ─────────────────────────────────────────────────────
GRAFANA_ADMIN_USER="CHANGE_ME"   # CHANGE_ME  Grafana web UI username
GRAFANA_ADMIN_PASSWORD=""        # Prompted at runtime — not stored in this file

# ── Pinned image versions ─────────────────────────────────────────────────────
# Update these tags when you want to upgrade. Check releases before changing:
#   Portainer:     https://github.com/portainer/portainer/releases
#   Prometheus:    https://github.com/prometheus/prometheus/releases
#   Node Exporter: https://github.com/prometheus/node_exporter/releases
#   Grafana:       https://github.com/grafana/grafana/releases
PORTAINER_IMAGE="portainer/portainer-ce:2.21.4"
PROMETHEUS_IMAGE="prom/prometheus:v2.53.2"
NODE_EXPORTER_IMAGE="prom/node-exporter:v1.8.2"
GRAFANA_IMAGE="grafana/grafana:11.3.2"

# ─────────────────────────────────────────────────────────────────────────────
#  DO NOT EDIT BELOW THIS LINE
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
NC='\033[0m'

log()     { echo -e "\n${GRN}[+]${NC} $*"; }
warn()    { echo -e "${YLW}[!]${NC} $*"; }
err()     { echo -e "\n${RED}[x] ERROR:${NC} $*\n"; exit 1; }
ok()      { echo -e "    ${GRN}✓${NC} $*"; }
fail()    { echo -e "    ${RED}✗${NC} $*"; }
section() {
    echo -e "\n${BLU}────────────────────────────────────────────────────${NC}"
    echo -e "${BLU}  $*${NC}"
    echo -e "${BLU}────────────────────────────────────────────────────${NC}"
}

# debug_check: runs a validation command at the end of each phase.
# Non-zero exit is shown as a warning, not a fatal error — phases already
# completed their work; this is a visibility tool, not a gate.
debug_check() {
    local label="$1"
    local cmd="$2"
    if eval "$cmd" &>/dev/null; then
        ok "$label"
    else
        fail "$label  (check manually: $cmd)"
    fi
}

# ── Validate configuration ────────────────────────────────────────────────────
validate_config() {
    local has_errors=0
    local ipv4_re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

    if [[ "$STATIC_IP" =~ X ]]; then
        warn "STATIC_IP not set"; has_errors=1
    elif ! [[ "$STATIC_IP" =~ $ipv4_re ]]; then
        warn "STATIC_IP does not look like a valid IPv4 address (got: $STATIC_IP)"; has_errors=1
    fi

    if [[ "$GATEWAY_IP" =~ X ]]; then
        warn "GATEWAY_IP not set"; has_errors=1
    elif ! [[ "$GATEWAY_IP" =~ $ipv4_re ]]; then
        warn "GATEWAY_IP does not look like a valid IPv4 address (got: $GATEWAY_IP)"; has_errors=1
    fi

    [[ "$NET_INTERFACE"      == "CHANGE_ME" ]] && { warn "NET_INTERFACE not set";      has_errors=1; }
    [[ "$NEW_USERNAME"       == "CHANGE_ME" ]] && { warn "NEW_USERNAME not set";       has_errors=1; }
    [[ "$PORTAINER_USERNAME" == "CHANGE_ME" ]] && { warn "PORTAINER_USERNAME not set"; has_errors=1; }
    [[ "$GRAFANA_ADMIN_USER" == "CHANGE_ME" ]] && { warn "GRAFANA_ADMIN_USER not set"; has_errors=1; }
    [[ "$SSH_PUBLIC_KEY" == "PASTE_YOUR_PUBLIC_KEY_HERE" ]] && { warn "SSH_PUBLIC_KEY not set"; has_errors=1; }

    # SSH public key format check
    if [[ "$SSH_PUBLIC_KEY" != "PASTE_YOUR_PUBLIC_KEY_HERE" ]]; then
        if ! [[ "$SSH_PUBLIC_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256)\ [A-Za-z0-9+/]+=*(\ .+)?$ ]]; then
            warn "SSH_PUBLIC_KEY does not look like a valid public key"
            has_errors=1
        fi
    fi

    [[ $has_errors -eq 1 ]] && err "Please fill in all CHANGE_ME values above, then re-run."
}

# ── Prompt for credentials interactively (never stored in this file) ──────────
prompt_credentials() {
    echo ""
    echo -e "${BLU}  Enter credentials (input is hidden — none are written to disk):${NC}"
    echo ""

    # OS user password
    while true; do
        read -rsp "  NEW_PASSWORD for $NEW_USERNAME: " NEW_PASSWORD; echo
        [[ -n "$NEW_PASSWORD" ]]     || { warn "Password cannot be empty"; continue; }
        [[ "$NEW_PASSWORD" != *:* ]] || { warn "Password must not contain a colon (:)"; continue; }
        read -rsp "  Confirm NEW_PASSWORD: " _confirm; echo
        [[ "$NEW_PASSWORD" == "$_confirm" ]] && break
        warn "Passwords do not match — try again"
    done

    # Portainer admin password (minimum 12 characters)
    while true; do
        read -rsp "  PORTAINER_PASSWORD (min 12 chars): " PORTAINER_PASSWORD; echo
        [[ ${#PORTAINER_PASSWORD} -ge 12 ]] || { warn "Must be at least 12 characters"; continue; }
        read -rsp "  Confirm PORTAINER_PASSWORD: " _confirm; echo
        [[ "$PORTAINER_PASSWORD" == "$_confirm" ]] && break
        warn "Passwords do not match — try again"
    done

    # Grafana admin password
    while true; do
        read -rsp "  GRAFANA_ADMIN_PASSWORD: " GRAFANA_ADMIN_PASSWORD; echo
        [[ -n "$GRAFANA_ADMIN_PASSWORD" ]] || { warn "Password cannot be empty"; continue; }
        read -rsp "  Confirm GRAFANA_ADMIN_PASSWORD: " _confirm; echo
        [[ "$GRAFANA_ADMIN_PASSWORD" == "$_confirm" ]] && break
        warn "Passwords do not match — try again"
    done
    echo ""
}

[[ $EUID -ne 0 ]] && err "Run as root: sudo bash server_setup.sh"
validate_config
prompt_credentials

echo ""
echo -e "${GRN}  Ubuntu 24.04 LTS — Server Baseline Setup${NC}"
echo -e "  Target static IP after reboot: ${YLW}${STATIC_IP}${NC}"
echo ""

# ==============================================================================
section "Phase 1 — System Update & Base Packages"
# ==============================================================================

log "Setting hostname to: $NEW_HOSTNAME"
hostnamectl set-hostname "$NEW_HOSTNAME"
grep -qF "$NEW_HOSTNAME" /etc/hosts || echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts

log "Updating package lists..."
apt-get update -qq

log "Upgrading installed packages (may take a few minutes)..."
DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -qq
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq

log "Installing required utilities..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl \
    ca-certificates \
    gnupg \
    jq \
    ufw \
    fail2ban

log "Capping journald log size — prevents unbounded disk growth"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-limits.conf <<'EOF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
RuntimeMaxUse=50M
EOF
systemctl restart systemd-journald

# ── Phase 1 debug ─────────────────────────────────────────────────────────────
echo ""
log "Phase 1 checks:"
debug_check "curl installed"       "command -v curl"
debug_check "jq installed"         "command -v jq"
debug_check "ufw installed"        "command -v ufw"
debug_check "fail2ban installed"   "command -v fail2ban-client"
debug_check "journald config"      "test -f /etc/systemd/journald.conf.d/99-limits.conf"

# ==============================================================================
section "Phase 2 — OS Security Hardening"
# ==============================================================================

log "Creating sudo user: $NEW_USERNAME"
if id "$NEW_USERNAME" &>/dev/null; then
    warn "User $NEW_USERNAME already exists — updating password and ensuring group membership"
    printf '%s:%s\n' "$NEW_USERNAME" "$NEW_PASSWORD" | chpasswd
    usermod -aG sudo "$NEW_USERNAME"
else
    useradd -m -s /bin/bash -G sudo "$NEW_USERNAME"
    printf '%s:%s\n' "$NEW_USERNAME" "$NEW_PASSWORD" | chpasswd
    log "User $NEW_USERNAME created"
fi

log "Configuring UFW firewall"
ufw --force reset          >/dev/null
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp    comment 'SSH'               >/dev/null
ufw allow 3000/tcp  comment 'Grafana'           >/dev/null
ufw allow 9090/tcp  comment 'Prometheus'        >/dev/null
ufw allow 9443/tcp  comment 'Portainer HTTPS'   >/dev/null
# Port 9000 (Portainer HTTP) is intentionally NOT opened — use 9443 (HTTPS) instead.
# Port 9100 (Node Exporter) is intentionally NOT opened — internal Docker network only.
ufw --force enable >/dev/null
log "UFW enabled — open: 22, 3000, 9090, 9443"

log "Configuring fail2ban — systemd backend (low CPU/RAM)"
# Using systemd backend: reads journald, no inotify on log files.
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ssh
maxretry = 3
EOF
systemctl enable --quiet fail2ban
systemctl restart fail2ban

# ── Phase 2 debug ─────────────────────────────────────────────────────────────
echo ""
log "Phase 2 checks:"
debug_check "User $NEW_USERNAME exists"  "id $NEW_USERNAME"
debug_check "UFW active"                 "ufw status | grep -q 'Status: active'"
debug_check "fail2ban running"           "systemctl is-active --quiet fail2ban"
debug_check "SSH port 22 rule in UFW"    "ufw status | grep -q '22/tcp'"

# ==============================================================================
section "Phase 3 — SSH Hardening"
# ==============================================================================

log "Installing SSH public key for $NEW_USERNAME"
SSH_DIR="/home/$NEW_USERNAME/.ssh"
mkdir -p "$SSH_DIR"
# Use printf to avoid echo misinterpreting keys starting with '-'
printf '%s\n' "$SSH_PUBLIC_KEY" > "$SSH_DIR/authorized_keys"
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$NEW_USERNAME:$NEW_USERNAME" "$SSH_DIR"

log "Applying SSH hardening rules"
mkdir -p /etc/ssh/sshd_config.d
# Static hardening options — single-quoted heredoc, no variable expansion needed
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
# Hardened by server_setup.sh
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
MaxAuthTries 4
LoginGraceTime 30
X11Forwarding no
EOF
# Dynamic: AllowUsers restricts login to this account only
echo "AllowUsers ${NEW_USERNAME}" >> /etc/ssh/sshd_config.d/99-hardening.conf

# Validate config before restarting — prevents lockout from typos
sshd -t || err "sshd config test failed — not restarting SSH to avoid lockout. Check /etc/ssh/sshd_config.d/99-hardening.conf"
systemctl restart ssh

# ── LOCKOUT WARNING — pause and verify key works before continuing ─────────────
echo ""
echo -e "${RED}──────────────────────────────────────────────────────────────────${NC}"
echo -e "${RED}  !! SSH KEY VERIFICATION REQUIRED BEFORE CONTINUING !!${NC}"
echo -e "${RED}──────────────────────────────────────────────────────────────────${NC}"
echo -e ""
echo -e "  Password login is now ${RED}DISABLED${NC} on this server."
echo ""
echo -e "  Open a ${YLW}NEW terminal${NC} right now and test SSH key login:"
echo -e "    ${YLW}ssh $NEW_USERNAME@$(hostname -I | awk '{print $1}')${NC}"
echo ""
echo -e "  If it works  →  type ${GRN}yes${NC} to continue"
echo -e "  If it fails  →  type ${RED}no${NC}  to exit safely"
echo ""
echo -e "  Recovery (if locked out):"
echo -e "    sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' \\"
echo -e "      /etc/ssh/sshd_config.d/99-hardening.conf && systemctl restart ssh"
echo -e "${RED}──────────────────────────────────────────────────────────────────${NC}"
echo ""
read -rp "  Did SSH key login succeed? [yes/no]: " SSH_CONFIRMED
if [[ "$SSH_CONFIRMED" != "yes" ]]; then
    warn "Aborting. SSH hardening is active but password auth is disabled."
    warn "Use the recovery command above from the console to regain access."
    exit 1
fi
log "SSH key confirmed — continuing"

# ── Phase 3 debug ─────────────────────────────────────────────────────────────
echo ""
log "Phase 3 checks:"
debug_check "sshd config syntax valid"    "sshd -t"
debug_check "SSH service running"         "systemctl is-active --quiet ssh"
debug_check "authorized_keys present"     "test -f $SSH_DIR/authorized_keys"
debug_check "PasswordAuthentication off"  "grep -q 'PasswordAuthentication no' /etc/ssh/sshd_config.d/99-hardening.conf"
debug_check "AllowUsers set"              "grep -q 'AllowUsers' /etc/ssh/sshd_config.d/99-hardening.conf"

# ==============================================================================
section "Phase 4 — Docker"
# ==============================================================================

if command -v docker &>/dev/null; then
    warn "Docker already installed — skipping"
else
    log "Adding Docker's official GPG key"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    log "Adding Docker apt repository (Ubuntu 24.04 / noble)"
    # The command substitution inside <<EOF expands at write time — intentional.
    # We want the literal codename 'noble' written to the file, not the expression.
    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    apt-get update -qq
    log "Installing Docker CE and Compose plugin"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
fi

log "Adding $NEW_USERNAME to docker group"
usermod -aG docker "$NEW_USERNAME"

log "Configuring Docker daemon — global log rotation + overlay2 storage"
mkdir -p /etc/docker
# Single-quoted heredoc: no variable expansion needed in daemon.json
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
EOF
systemctl enable --quiet docker
systemctl restart docker

# ── Phase 4 debug ─────────────────────────────────────────────────────────────
echo ""
log "Phase 4 checks:"
debug_check "Docker daemon running"       "systemctl is-active --quiet docker"
debug_check "docker compose plugin"       "docker compose version"
debug_check "overlay2 storage driver"     "docker info 2>/dev/null | grep -q 'overlay2'"
debug_check "json-file log driver"        "docker info 2>/dev/null | grep -q 'json-file'"
debug_check "$NEW_USERNAME in docker grp" "groups $NEW_USERNAME | grep -q docker"

# ==============================================================================
section "Phase 5 — Portainer CE"
# ==============================================================================

log "Deploying Portainer CE — $PORTAINER_IMAGE"
if docker ps -a --format '{{.Names}}' | grep -q '^portainer$'; then
    warn "Portainer container already exists — skipping launch"
else
    docker volume create portainer_data >/dev/null
    # NOTE: /var/run/docker.sock grants Portainer root-equivalent host access — standard Portainer trade-off.
    docker run -d \
        --name portainer \
        --restart=unless-stopped \
        -p 127.0.0.1:9000:9000 \
        -p 9443:9443 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        --log-driver json-file \
        --log-opt max-size=10m \
        --log-opt max-file=3 \
        "$PORTAINER_IMAGE" >/dev/null
    log "Portainer container started"
fi

log "Waiting for Portainer API to become ready..."
PORTAINER_URL="http://127.0.0.1:9000"
ATTEMPTS=0
until curl -sf "${PORTAINER_URL}/api/status" >/dev/null 2>&1; do
    ATTEMPTS=$((ATTEMPTS + 1))
    [[ $ATTEMPTS -ge 30 ]] && err "Portainer did not respond after 60 seconds. Check: docker logs portainer"
    sleep 2
done
log "Portainer API ready"

log "Initialising Portainer admin account: $PORTAINER_USERNAME"
# jq constructs the JSON — handles any special characters in credentials safely
INIT_PAYLOAD=$(jq -n \
    --arg u "$PORTAINER_USERNAME" \
    --arg p "$PORTAINER_PASSWORD" \
    '{Username: $u, Password: $p}')

INIT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$INIT_PAYLOAD" \
    "${PORTAINER_URL}/api/users/admin/init")

if   [[ "$INIT_STATUS" == "200" ]]; then log "Portainer admin account created"
elif [[ "$INIT_STATUS" == "409" ]]; then warn "Portainer admin already exists — continuing"
else err "Portainer admin init returned HTTP $INIT_STATUS (expected 200)"
fi

log "Authenticating with Portainer API"
# Note: auth endpoint uses lowercase username/password (different from init)
AUTH_PAYLOAD=$(jq -n \
    --arg u "$PORTAINER_USERNAME" \
    --arg p "$PORTAINER_PASSWORD" \
    '{username: $u, password: $p}')

JWT=$(curl -sf \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$AUTH_PAYLOAD" \
    "${PORTAINER_URL}/api/auth" \
    | jq -r '.jwt')

[[ -z "$JWT" || "$JWT" == "null" ]] && err "Failed to get Portainer JWT token. Check credentials."

log "Fetching local Docker endpoint ID"
ENDPOINT_ID=$(curl -sf \
    -H "Authorization: Bearer $JWT" \
    "${PORTAINER_URL}/api/endpoints" \
    | jq '.[0].Id')

[[ -z "$ENDPOINT_ID" || "$ENDPOINT_ID" == "null" ]] && err "Failed to get Portainer endpoint ID"
log "Portainer endpoint ID: $ENDPOINT_ID"

# ── Phase 5 debug ─────────────────────────────────────────────────────────────
echo ""
log "Phase 5 checks:"
debug_check "Portainer container running"  "docker inspect portainer --format '{{.State.Status}}' | grep -q running"
debug_check "Portainer API responding"     "curl -sf ${PORTAINER_URL}/api/status"
debug_check "JWT token obtained"           "test -n \"$JWT\""
debug_check "Endpoint ID obtained"         "test -n \"$ENDPOINT_ID\""

# ==============================================================================
section "Phase 6 — Monitoring Stack (Prometheus + Node Exporter + Grafana)"
# ==============================================================================
#
#  Architecture:
#    - All three containers share an internal Docker bridge: monitoring_net
#    - Prometheus scrapes Node Exporter at node-exporter:9100 internally
#    - Port 9100 is NOT exposed externally — UFW has no rule for it
#    - Grafana datasource is auto-provisioned via Compose configs block
#    - Credentials are passed via Portainer API Env array — no .env file needed
#    - Prometheus and Grafana config are embedded in the compose via configs:
#      content — self-contained, no host bind mounts required
#

log "Building monitoring stack Compose YAML"

# Single-quoted heredoc: $ signs inside are literal (not bash variables).
# This is intentional — the Compose variable references (${GF_SECURITY_ADMIN_USER}
# etc.) must reach docker-compose as-is so Portainer can substitute them
# from the Env array we pass in the API call.
# The || true suppresses the exit code 1 that 'read -d' returns on EOF.
read -r -d '' COMPOSE_YAML <<'COMPOSE_EOF' || true
services:

  prometheus:
    image: PROMETHEUS_IMAGE_PLACEHOLDER
    container_name: prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=15d'
      - '--web.console.libraries=/usr/share/prometheus/console_libraries'
      - '--web.console.templates=/usr/share/prometheus/consoles'
    configs:
      - source: prometheus_config
        target: /etc/prometheus/prometheus.yml
    ports:
      - "9090:9090"
    volumes:
      - prometheus_data:/prometheus
    networks:
      - monitoring_net
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  node-exporter:
    image: NODE_EXPORTER_IMAGE_PLACEHOLDER
    container_name: node-exporter
    command:
      - '--path.rootfs=/host'
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|run|snap)($|/)'
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/host:ro,rslave
    networks:
      - monitoring_net
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "5m"
        max-file: "2"

  grafana:
    image: GRAFANA_IMAGE_PLACEHOLDER
    container_name: grafana
    environment:
      - GF_SECURITY_ADMIN_USER=${GF_ADMIN_USER}
      - GF_SECURITY_ADMIN_PASSWORD=${GF_ADMIN_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SERVER_ROOT_URL=http://localhost:3000
      - GF_LOG_MODE=console
      - GF_LOG_LEVEL=warn
      - GF_ANALYTICS_REPORTING_ENABLED=false
    configs:
      - source: grafana_datasource
        target: /etc/grafana/provisioning/datasources/prometheus.yml
    ports:
      - "3000:3000"
    volumes:
      - grafana_data:/var/lib/grafana
    depends_on:
      - prometheus
    networks:
      - monitoring_net
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  monitoring_net:
    driver: bridge

volumes:
  prometheus_data:
    driver: local
  grafana_data:
    driver: local

configs:
  prometheus_config:
    content: |
      global:
        scrape_interval:     15s
        evaluation_interval: 15s
      scrape_configs:
        - job_name: 'prometheus'
          static_configs:
            - targets: ['localhost:9090']
        - job_name: 'node'
          static_configs:
            - targets: ['node-exporter:9100']

  grafana_datasource:
    content: |
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          access: proxy
          url: http://prometheus:9090
          isDefault: true
          editable: true
          jsonData:
            timeInterval: "15s"
COMPOSE_EOF

# Substitute image placeholders now that variable expansion is available.
# The single-quoted heredoc above kept them as literals; sed replaces them here.
COMPOSE_YAML="${COMPOSE_YAML//PROMETHEUS_IMAGE_PLACEHOLDER/$PROMETHEUS_IMAGE}"
COMPOSE_YAML="${COMPOSE_YAML//NODE_EXPORTER_IMAGE_PLACEHOLDER/$NODE_EXPORTER_IMAGE}"
COMPOSE_YAML="${COMPOSE_YAML//GRAFANA_IMAGE_PLACEHOLDER/$GRAFANA_IMAGE}"

log "Deploying monitoring stack via Portainer API"
# jq handles all JSON encoding — special characters in passwords are safe
STACK_PAYLOAD=$(jq -n \
    --arg name  "monitoring" \
    --arg yaml  "$COMPOSE_YAML" \
    --arg guser "$GRAFANA_ADMIN_USER" \
    --arg gpass "$GRAFANA_ADMIN_PASSWORD" \
    '{
        Name:             $name,
        StackFileContent: $yaml,
        Env: [
            {name: "GF_ADMIN_USER",     value: $guser},
            {name: "GF_ADMIN_PASSWORD", value: $gpass}
        ]
    }')

STACK_RESPONSE_FILE=$(mktemp)
STACK_STATUS=$(curl -s \
    -o "$STACK_RESPONSE_FILE" \
    -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/json" \
    -d "$STACK_PAYLOAD" \
    "${PORTAINER_URL}/api/stacks/create/standalone/string?endpointId=${ENDPOINT_ID}")

if [[ "$STACK_STATUS" == "200" || "$STACK_STATUS" == "201" ]]; then
    STACK_ID=$(jq -r '.Id' "$STACK_RESPONSE_FILE" 2>/dev/null || echo "unknown")
    rm -f "$STACK_RESPONSE_FILE"
    log "Monitoring stack deployed (Portainer stack ID: $STACK_ID)"
elif grep -qi "already exist" "$STACK_RESPONSE_FILE" 2>/dev/null; then
    rm -f "$STACK_RESPONSE_FILE"
    warn "Stack 'monitoring' already exists in Portainer — skipping"
else
    echo ""
    warn "Stack deployment returned HTTP $STACK_STATUS. Portainer response:"
    cat "$STACK_RESPONSE_FILE"
    rm -f "$STACK_RESPONSE_FILE"
    err "Monitoring stack deployment failed"
fi

log "Waiting for Grafana to become ready (up to 90s)..."
ATTEMPTS=0
until curl -sf http://127.0.0.1:3000/api/health >/dev/null 2>&1; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [[ $ATTEMPTS -ge 30 ]]; then
        warn "Grafana not ready yet — it may still be pulling the image. Check Portainer UI."
        break
    fi
    sleep 3
done
[[ $ATTEMPTS -lt 30 ]] && log "Grafana is up and responding"

# ── Phase 6 debug ─────────────────────────────────────────────────────────────
echo ""
log "Phase 6 checks:"
debug_check "Prometheus container running"     "docker ps --format '{{.Names}}' | grep -q '^prometheus$'"
debug_check "Node Exporter container running"  "docker ps --format '{{.Names}}' | grep -q '^node-exporter$'"
debug_check "Grafana container running"        "docker ps --format '{{.Names}}' | grep -q '^grafana$'"
debug_check "Grafana health endpoint"          "curl -sf http://127.0.0.1:3000/api/health | jq -e '.database == \"ok\"'"
debug_check "Prometheus targets reachable"     "curl -sf http://127.0.0.1:9090/api/v1/targets | jq -e '.status == \"success\"'"
debug_check "Port 9100 NOT exposed on host"    "! ss -tlnp | grep -q ':9100'"

# ==============================================================================
section "Phase 7 — Static IP via Netplan (applied on reboot)"
# ==============================================================================
#
#  This is done LAST so the current DHCP session stays alive for the whole script.
#  The IP change takes effect only after: sudo reboot
#

log "Detecting netplan renderer..."
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    NETPLAN_RENDERER="NetworkManager"
    log "Renderer: NetworkManager"
else
    NETPLAN_RENDERER="networkd"
    log "Renderer: networkd"
fi

# Prevent cloud-init from regenerating its network config on next boot
# and overwriting the static IP we're about to write.
log "Disabling cloud-init network management"
mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
network: {config: disabled}
EOF

# Disable (not delete) cloud-init's auto-generated netplan file if present.
# Renaming preserves it as a reference and removes it from netplan's sort order.
if [[ -f /etc/netplan/50-cloud-init.yaml ]]; then
    mv /etc/netplan/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml.disabled
    log "Renamed 50-cloud-init.yaml → 50-cloud-init.yaml.disabled"
fi

log "Writing static IP netplan config — interface: $NET_INTERFACE"
# Unquoted heredoc (<<EOF): expands $STATIC_IP, $SUBNET_PREFIX, etc. — intentional.
# The 'gateway4' key is deprecated in Ubuntu 24.04; use 'routes: to: default' instead.
cat > /etc/netplan/99-static.yaml <<EOF
# Written by server_setup.sh — do not edit manually
network:
  version: 2
  renderer: ${NETPLAN_RENDERER}
  ethernets:
    ${NET_INTERFACE}:
      dhcp4: false
      addresses:
        - ${STATIC_IP}/${SUBNET_PREFIX}
      routes:
        - to: default
          via: ${GATEWAY_IP}
      nameservers:
        addresses: [${DNS_SERVERS}]
EOF
chmod 600 /etc/netplan/99-static.yaml

# Validate syntax and generate backend config (dry run — does NOT apply)
# Do NOT run 'netplan apply' here — it would drop the current SSH session.
if netplan generate 2>/dev/null; then
    log "Netplan config validated — will activate on reboot"
else
    warn "Netplan config may have issues. Review /etc/netplan/99-static.yaml before rebooting."
fi

# ── Phase 7 debug ─────────────────────────────────────────────────────────────
echo ""
log "Phase 7 checks:"
debug_check "Netplan config written"           "test -f /etc/netplan/99-static.yaml"
debug_check "cloud-init network disabled"      "test -f /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"
debug_check "cloud-init netplan neutralised"   "test ! -f /etc/netplan/50-cloud-init.yaml"
debug_check "Netplan config validated"         "netplan generate"

# ==============================================================================
section "Setup Complete"
# ==============================================================================

CURRENT_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GRN}──────────────────────────────────────────────────────────────────${NC}"
echo -e "${GRN}  All phases complete!${NC}"
echo -e "${GRN}──────────────────────────────────────────────────────────────────${NC}"
echo -e "${GRN}  Hostname        :${NC} $NEW_HOSTNAME"
echo -e "${GRN}  Current IP      :${NC} $CURRENT_IP"
echo -e "${GRN}  Static IP       :${NC} $STATIC_IP  (active after reboot)"
echo -e "${GRN}  Admin user      :${NC} $NEW_USERNAME"
echo -e "${GRN}──────────────────────────────────────────────────────────────────${NC}"
echo -e "${GRN}  Services (use current IP until reboot, then use static IP)${NC}"
echo -e "${GRN}  Portainer       :${NC} https://${STATIC_IP}:9443  (HTTP port 9000 is loopback-only)"
echo -e "${GRN}  Prometheus      :${NC} http://${STATIC_IP}:9090"
echo -e "${GRN}  Grafana         :${NC} http://${STATIC_IP}:3000"
echo -e "${GRN}──────────────────────────────────────────────────────────────────${NC}"
echo -e "${GRN}  UFW open ports  :${NC} 22, 3000, 9090, 9443"
echo -e "${GRN}  Port 9100       :${NC} CLOSED externally (Node Exporter — internal only)"
echo -e "${GRN}──────────────────────────────────────────────────────────────────${NC}"
echo ""
echo -e "  Post-setup steps:"
echo -e ""
echo -e "  ${YLW}1. Reboot now:${NC}  sudo reboot"
echo -e "     After reboot, reconnect to: ${YLW}ssh $NEW_USERNAME@$STATIC_IP${NC}"
echo ""
echo -e "  2. Open Portainer → Stacks → verify 'monitoring' stack is Running"
echo ""
echo -e "  3. Open Grafana → Connections → Data sources"
echo -e "     Prometheus should already be listed and connected"
echo ""
echo -e "  4. Add a Node Exporter dashboard:"
echo -e "     Dashboards → Import → enter ID ${YLW}1860${NC} → select Prometheus → Import"
echo -e "     (Grafana ID 1860 is the popular Node Exporter Full dashboard)"
echo ""
echo -e "${GRN}──────────────────────────────────────────────────────────────────${NC}"
echo ""
