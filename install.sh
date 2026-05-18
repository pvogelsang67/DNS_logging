
#!/bin/bash
# =============================================================================
# install.sh — DNS_logging Stack Installer
# GitHub: https://github.com/pvogelsang67/DNS_logging
#
# Usage:
#   sudo bash install.sh
#    or one-liner from GitHub (interactive terminal required for API key prompt):
#   curl -fsSL https://raw.githubusercontent.com/pvogelsang67/DNS_logging/main/install.sh | sudo bash
#
# Non-interactive / pre-seeded API key:
#   sudo TIDE_API_KEY="<your-key>" ./install.sh
#
# What this script does:
#   1. Detects and removes any prior installation
#   2. Installs Docker CE + Compose plugin (if not present)
#   3. Installs git (if not present)
#   4. Clones the DNS_logging repo to /opt/DNS_logging
#   5. Prompts for Infoblox CSP API key and writes it to dns-rpz-logging/.env
#   6. Tunes vm.max_map_count required by Elasticsearch
#   7. Starts all containers via the unified docker-compose.yml
#   8. Verifies all containers reach a running state
# =============================================================================
set -euo pipefail

# — Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; \
          echo -e "${CYAN}  $1${NC}"; \
          echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# — Config
INSTALL_DIR="/opt/DNS_logging"
GITHUB_REPO="https://github.com/pvogelsang67/DNS_logging.git"
CONTAINERS=("es01" "kibana" "logstash" "dnscollector")
STARTUP_WAIT=45   # seconds to wait after docker compose up

# — Must run as root
if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root. Try:  sudo bash install.sh"
fi

# — OS check
if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
  warn "This script is designed for Ubuntu. Continuing anyway, but results may vary."
fi

#
step "STEP 1 — Removing prior installation (if any)"
#
FOUND_CONTAINERS=()
for c in "${CONTAINERS[@]}"; do
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
    FOUND_CONTAINERS+=("$c")
  fi
done

if [[ ${#FOUND_CONTAINERS[@]} -gt 0 ]]; then
  warn "Found existing containers: ${FOUND_CONTAINERS[*]}"
  log "Stopping and removing containers..."
  docker stop "${FOUND_CONTAINERS[@]}" 2>/dev/null || true
  docker rm   "${FOUND_CONTAINERS[@]}" 2>/dev/null || true
  log "Containers removed."
else
  log "No existing containers found."
fi

if [[ -d "$INSTALL_DIR" ]]; then
  warn "Found existing installation directory at $INSTALL_DIR — removing..."
  rm -rf "$INSTALL_DIR"
  log "Directory removed."
else
  log "No existing installation directory found."
fi

#
step "STEP 2 — Installing Docker"
#
if command -v docker &>/dev/null; then
  log "Docker is already installed: $(docker --version)"
else
  log "Docker not found — installing Docker CE..."
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  systemctl enable docker
  systemctl start docker
  log "Docker installed: $(docker --version)"
fi

# Verify docker compose plugin
if ! docker compose version &>/dev/null; then
  error "Docker Compose plugin not found. Install it with: apt-get install docker-compose-plugin"
fi
log "Docker Compose: $(docker compose version --short)"

#
step "STEP 3 — Installing git"
#
if command -v git &>/dev/null; then
  log "git already installed: $(git --version)"
else
  log "Installing git..."
  apt-get install -y -qq git
  log "git installed: $(git --version)"
fi

#
step "STEP 4 — Cloning DNS_logging repository"
#
log "Cloning $GITHUB_REPO → $INSTALL_DIR ..."
git clone "$GITHUB_REPO" "$INSTALL_DIR"
log "Repository cloned successfully."
#
step "STEP 5  Configuring Infoblox CSP API Key (TIDE enrichment)"
#
ENV_FILE="$INSTALL_DIR/dns-rpz-logging/.env"
echo ""
echo -e "  ${CYAN}RPZ log enrichment with Infoblox TIDE threat intelligence requires${NC}"
echo -e "  ${CYAN}an API key from the Infoblox Cloud Services Portal (CSP).${NC}"
echo -e "  ${CYAN}Get your API key at: https://csp.infoblox.com${NC}"
echo -e "  ${CYAN}   Administration  User Profile  API Keys  Create API Key${NC}"
echo ""

# Support non-interactive mode: allow pre-seeding via environment variable
if [[ -n "${TIDE_API_KEY:-}" ]]; then
  log "Using TIDE_API_KEY from environment variable."
else
  # When piping via `curl | bash`, stdin is the curl pipe — not the terminal.
  # Redirect read to /dev/tty so it always prompts the user directly.
  if [[ ! -e /dev/tty ]]; then
    error "No TTY available for interactive input. Pre-seed the key with:  TIDE_API_KEY='<your-key>' bash install.sh"
  fi

  TIDE_API_KEY=""
  while [[ -z "$TIDE_API_KEY" ]]; do
    read -r -p "  Enter your Infoblox CSP API Key: " TIDE_API_KEY </dev/tty
    if [[ -z "$TIDE_API_KEY" ]]; then
      warn "API key cannot be empty. Please enter a valid key."
    fi
  done
fi

if [[ -f "$ENV_FILE" ]]; then
  sed -i "s|^TIDE_API_KEY=.*|TIDE_API_KEY=${TIDE_API_KEY}|" "$ENV_FILE"
  log "TIDE API key written to $ENV_FILE"
else
  echo "TIDE_API_KEY=${TIDE_API_KEY}" > "$ENV_FILE"
  log "Created $ENV_FILE with TIDE API key."
fi


#
step "STEP 6 — Tuning system settings for Elasticsearch"
#
CURRENT_MAP=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
if [[ "$CURRENT_MAP" -lt 262144 ]]; then
  log "Setting vm.max_map_count=262144 (was: $CURRENT_MAP)..."
  sysctl -w vm.max_map_count=262144
  # Persist across reboots
  if ! grep -q "vm.max_map_count" /etc/sysctl.conf; then
    echo "vm.max_map_count=262144" >> /etc/sysctl.conf
  else
    sed -i 's/^vm.max_map_count=.*/vm.max_map_count=262144/' /etc/sysctl.conf
  fi
  log "vm.max_map_count set and persisted to /etc/sysctl.conf"
else
  log "vm.max_map_count already sufficient ($CURRENT_MAP)."
fi
#
step "STEP 7  Starting all Docker containers"
#
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
if [[ ! -f "$COMPOSE_FILE" ]]; then
  error "Unified docker-compose.yml not found at $COMPOSE_FILE. \
Please ensure the file exists in the repo root before running this script."
fi

# ── Stage 1: bring up Elasticsearch and Kibana ──────────────────────────────
log "Starting Elasticsearch and Kibana..."
docker compose -f "$COMPOSE_FILE" up -d elasticsearch kibana

# Wait for Elasticsearch
log "Waiting for Elasticsearch to be ready (up to 5 min)..."
ES_READY=false
for i in $(seq 1 60); do
  ES_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    http://localhost:9200/_cluster/health 2>/dev/null || echo "000")
  if [[ "$ES_STATUS" == "200" ]]; then
    log "Elasticsearch is ready (HTTP 200) after $((i * 5))s."
    ES_READY=true
    break
  fi
  echo -n "."
  sleep 5
done
echo ""
if [[ "$ES_READY" != "true" ]]; then
  error "Elasticsearch did not become ready within 5 minutes. Check logs: docker logs es01"
fi

# Wait for Kibana
log "Waiting for Kibana to be ready (up to 5 min)..."
KIBANA_READY=false
for i in $(seq 1 60); do
  KIBANA_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    http://localhost:5601/api/status 2>/dev/null || echo "000")
  if [[ "$KIBANA_STATUS" == "200" ]]; then
    log "Kibana is ready (HTTP 200) after $((i * 5))s."
    KIBANA_READY=true
    break
  fi
  echo -n "."
  sleep 5
done
echo ""
if [[ "$KIBANA_READY" != "true" ]]; then
  error "Kibana did not become ready within 5 minutes. Check logs: docker logs kibana"
fi

# ── Stage 2: bring up Logstash and DNSCollector ──────────────────────────────
log "Starting Logstash and DNSCollector..."
docker compose -f "$COMPOSE_FILE" up -d logstash dnscollector
log "All four containers are up."


step "STEP 8 — Verifying container status"
#
FAILED=()
for container in "${CONTAINERS[@]}"; do
  STATUS=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "not found")
  if [[ "$STATUS" == "running" ]]; then
    echo -e "  ${GREEN}✔${NC}  $container  →  running"
  else
    echo -e "  ${RED}✖${NC}  $container  →  $STATUS"
    FAILED+=("$container")
  fi
done
echo ""

if [[ ${#FAILED[@]} -gt 0 ]]; then
  warn "The following container(s) did not reach running state: ${FAILED[*]}"
  warn "Inspect logs with:"
  for c in "${FAILED[@]}"; do
    warn "  docker logs $c"
  done
  exit 1
fi

# Health check — Elasticsearch HTTP
log "Performing Elasticsearch health check..."
ES_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9200/_cluster/health || echo "000")
if [[ "$ES_STATUS" == "200" ]]; then
  log "Elasticsearch health endpoint responded OK (HTTP 200)."
else
  warn "Elasticsearch health endpoint returned HTTP $ES_STATUS — it may still be warming up."
fi
#
step "STEP 9  Importing Kibana dashboard"
#
DASHBOARD_FILE="$INSTALL_DIR/elasticsearch/dnstap_dashboard.ndjson"

if [[ ! -f "$DASHBOARD_FILE" ]]; then
  warn "Dashboard file not found at $DASHBOARD_FILE — skipping automatic import."
  warn "Import it manually via: Stack Management → Kibana → Saved Objects → Import"
else
  log "Importing Kibana saved objects from $DASHBOARD_FILE ..."

  # Retry loop — Kibana's saved objects API can briefly return 503 even after
  # /api/status reports 200 while internal plugins finish initialising.
  IMPORT_SUCCESS=false
  for attempt in 1 2 3; do
    IMPORT_RESPONSE=$(curl -s -X POST \
      "http://localhost:5601/api/saved_objects/_import?overwrite=true" \
      -H "kbn-xsrf: true" \
      -F "file=@${DASHBOARD_FILE}" 2>/dev/null || echo '{"success":false}')

    if echo "$IMPORT_RESPONSE" | grep -q '"success":true'; then
      log "Kibana dashboard imported successfully."
      IMPORT_SUCCESS=true
      break
    else
      warn "Import attempt $attempt failed — waiting 10s before retry..."
      sleep 10
    fi
  done

  if [[ "$IMPORT_SUCCESS" != "true" ]]; then
    warn "Kibana dashboard could not be imported automatically."
    warn "Import it manually:"
    warn "  1. Open http://<server-ip>:5601"
    warn "  2. Stack Management → Kibana → Saved Objects → Import"
    warn "  3. Select file: $DASHBOARD_FILE"
  fi
fi

# Summary
HOST_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}       DNS_logging Stack — Install Complete       ${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${CYAN}Kibana Dashboard:${NC}        http://${HOST_IP}:5601"
echo -e "  ${CYAN}Elasticsearch API:${NC}       http://${HOST_IP}:9200"
echo -e "  ${CYAN}DNSCollector Web UI:${NC}     http://${HOST_IP}:8080"
echo -e "  ${CYAN}DNSCollector DNSTap:${NC}     ${HOST_IP}:6000/tcp"
echo -e "  ${CYAN}DNSCollector Metrics:${NC}    http://${HOST_IP}:9165"
echo -e "  ${CYAN}Syslog (RPZ):${NC}            ${HOST_IP}:514/udp  |  ${HOST_IP}:514/tcp"
echo ""
echo -e "  Install directory: ${INSTALL_DIR}"
echo -e "  To stop:   sudo docker compose -f ${COMPOSE_FILE} down"
echo -e "  To start:  sudo docker compose -f ${COMPOSE_FILE} up -d"
echo ""
