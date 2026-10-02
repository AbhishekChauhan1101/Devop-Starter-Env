#!/usr/bin/env bash
# =============================================================================
#  monitoring-setup.sh  -  Server + Application monitoring in ONE script
#
#  Stack : Prometheus · Grafana · Alertmanager · Node Exporter · cAdvisor ·
#          Blackbox Exporter  (all via Docker Compose)
#  Target: Ubuntu / Debian (EC2, VM, bare metal, WSL2)
#
#  Run   : chmod +x monitoring-setup.sh && ./monitoring-setup.sh
#  Help  : ./monitoring-setup.sh help
# =============================================================================

set -uo pipefail
umask 022

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.0.0"

MON_DIR="${MON_DIR:-$HOME/monitoring-stack}"
ASSUME_YES=false
DRY_RUN=false
DOCKER=(docker)

# ---- component versions (change in $MON_DIR/.env, then: ./monitoring-setup.sh update)
PROMETHEUS_VERSION="${PROMETHEUS_VERSION:-v2.55.1}"
ALERTMANAGER_VERSION="${ALERTMANAGER_VERSION:-v0.27.0}"
GRAFANA_VERSION="${GRAFANA_VERSION:-11.3.0}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-v1.8.2}"
BLACKBOX_VERSION="${BLACKBOX_VERSION:-v0.25.0}"
CADVISOR_VERSION="${CADVISOR_VERSION:-v0.49.1}"

# ---- options (filled by the wizard)
ENABLE_CONTAINERS=true
ENABLE_UPTIME=true
ENABLE_NODE_CONTAINER=true     # run node-exporter container for THIS host
ENABLE_NODE_TARGET=true        # scrape host.docker.internal:9100
GRAFANA_USER="admin"
GRAFANA_PASS=""
GRAFANA_BIND="0.0.0.0"
PROM_BIND="127.0.0.1"
ALERT_BIND="127.0.0.1"
GRAFANA_PORT="3000"
PROM_PORT="9090"
ALERT_PORT="9093"
RETENTION_DAYS="15"
ALERT_CHANNEL="none"
SLACK_URL=""; TG_TOKEN=""; TG_CHAT=""
SMTP_TO=""; SMTP_FROM=""; SMTP_HOST=""; SMTP_USER=""; SMTP_PASS=""

# ----------------------------- output helpers --------------------------------
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; NC=""
fi
info()    { printf "%s[i]%s %s\n" "$BLUE" "$NC" "$*"; }
ok()      { printf "%s[✔]%s %s\n" "$GREEN" "$NC" "$*"; }
warn()    { printf "%s[!]%s %s\n" "$YELLOW" "$NC" "$*"; }
err()     { printf "%s[✘]%s %s\n" "$RED" "$NC" "$*" >&2; }
die()     { err "$*"; exit 1; }
section() { printf "\n%s━━━ %s ━━━%s\n" "$BOLD$CYAN" "$*" "$NC"; }

# ------------------------------ generic helpers ------------------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

port_in_use() {
  local p="$1"
  if has_cmd ss; then
    ss -H -ltn "sport = :$p" 2>/dev/null | grep -q .
  else
    (exec 4<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null
  fi
}

yaml_sq()        { printf '%s' "${1//\'/\'\'}"; }          # escape ' for YAML '...'
gen_password()   { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16; }
valid_name()     { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
valid_hostport() { [[ "$1" =~ ^[A-Za-z0-9._-]+(:[0-9]{1,5})?$ ]]; }
valid_password() { [[ "$1" =~ ^[A-Za-z0-9_@%+=.-]{8,64}$ ]]; }
valid_url() {
  case "$1" in
    *\'*|*\"*|*\\*|*" "*) return 1 ;;
    http://?*|https://?*) return 0 ;;
    *) return 1 ;;
  esac
}

public_ip() {
  local t="" ip=""
  t="$(curl -fsS -m 2 -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)" || t=""
  if [ -n "$t" ]; then
    ip="$(curl -fsS -m 2 -H "X-aws-ec2-metadata-token: $t" \
          http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)" || ip=""
  fi
  if [ -z "$ip" ]; then
    ip="$(curl -fsS -m 3 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')" || ip=""
  fi
  if [ -z "$ip" ]; then ip="$(hostname -I 2>/dev/null | awk '{print $1}')"; fi
  printf '%s' "${ip:-<server-ip>}"
}
private_ip() { hostname -I 2>/dev/null | awk '{print $1}'; }

# ------------------------------ prompts --------------------------------------
init_tty() {
  $ASSUME_YES && return 0
  if [ -r /dev/tty ] && : </dev/tty 2>/dev/null; then exec 3</dev/tty; else exec 3<&0; fi
}

ask_yn() {  # ask_yn "question" y|n   -> 0 = yes
  local prompt="$1" def="${2:-n}" ans hint
  if [ "$def" = "y" ]; then hint="Y/n"; else hint="y/N"; fi
  if $ASSUME_YES; then [ "$def" = "y" ]; return; fi
  while true; do
    read -r -u 3 -p "${CYAN}?${NC} ${prompt} [${hint}]: " ans || die "No input available."
    ans="${ans:-$def}"
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     warn "Please answer y or n." ;;
    esac
  done
}

ask_text() {  # ask_text "question" "default" VARNAME
  local prompt="$1" def="$2" __var="$3" ans
  if $ASSUME_YES; then printf -v "$__var" '%s' "$def"; return 0; fi
  read -r -u 3 -p "${CYAN}?${NC} ${prompt}${def:+ [$def]}: " ans || die "No input available."
  printf -v "$__var" '%s' "${ans:-$def}"
}

pick_port() {  # pick_port "label" default VARNAME
  local label="$1" def="$2" __v="$3" p="$2"
  while port_in_use "$p"; do
    warn "Port $p ($label) is already in use on this machine."
    $ASSUME_YES && die "Free port $p, or run interactively to pick another one."
    ask_text "Choose another port for $label" "$((p + 1))" p
    if ! { [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1024 ] && [ "$p" -le 65535 ]; }; then
      warn "Invalid port."; p="$def"
    fi
  done
  printf -v "$__v" '%s' "$p"
}

# ------------------------------ docker helpers -------------------------------
setup_docker_cmd() {
  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
  elif [ "$(id -u)" -ne 0 ] && has_cmd sudo && sudo docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
  else
    return 1
  fi
}

ensure_docker() {
  section "Checking Docker"
  if ! has_cmd docker; then
    warn "Docker is not installed."
    ask_yn "Install Docker + Compose v2 now (from the Ubuntu/Debian repo)?" y \
      || die "Docker is required. Install it and re-run."
    has_cmd apt-get || die "Automatic install supports apt-based systems only."
    as_root apt-get update -y || die "apt-get update failed."
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io curl \
      || die "Could not install docker.io."
    as_root usermod -aG docker "$(id -un)" 2>/dev/null || true
    ok "Docker installed."
  fi

  if ! docker compose version >/dev/null 2>&1 && ! as_root docker compose version >/dev/null 2>&1; then
    warn "Docker Compose v2 plugin not found - installing..."
    local p done=false
    for p in docker-compose-v2 docker-compose-plugin; do
      if apt-cache show "$p" >/dev/null 2>&1; then
        as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" && { done=true; break; }
      fi
    done
    $done || die "Could not install the Docker Compose plugin. Install 'docker compose' v2 manually."
  fi

  if ! docker info >/dev/null 2>&1 && ! as_root docker info >/dev/null 2>&1; then
    info "Starting Docker daemon..."
    as_root systemctl enable --now docker 2>/dev/null || as_root service docker start 2>/dev/null || true
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      as_root docker info >/dev/null 2>&1 && break
      sleep 2
    done
  fi

  setup_docker_cmd || die "Docker daemon is not reachable. Try: sudo systemctl start docker"
  if [ "${DOCKER[0]}" = "sudo" ]; then
    warn "Using 'sudo docker' (your docker group isn't active in this shell yet - that's fine)."
  fi
  ok "$("${DOCKER[@]}" --version)  |  $("${DOCKER[@]}" compose version | head -n1)"
}

compose() { ( cd "$MON_DIR" && "${DOCKER[@]}" compose "$@" ); }

load_env() {
  # shellcheck disable=SC1091
  if [ -f "$MON_DIR/.env" ]; then . "$MON_DIR/.env"; fi
  GRAFANA_PORT="${GRAFANA_PORT:-3000}"
  PROM_PORT="${PROM_PORT:-9090}"
  ALERT_PORT="${ALERT_PORT:-9093}"
}

require_stack() {
  [ -f "$MON_DIR/docker-compose.yml" ] \
    || die "No monitoring stack found in $MON_DIR. Run '$SCRIPT_NAME server' first (or use --dir <path>)."
  load_env
  setup_docker_cmd || die "Docker is not running or not accessible."
}

# ------------------------------ file generators ------------------------------
gen_env() {
  local profiles=()
  [ "$ENABLE_NODE_CONTAINER" = true ] && profiles+=(node)
  [ "$ENABLE_CONTAINERS" = true ]     && profiles+=(containers)
  [ "$ENABLE_UPTIME" = true ]         && profiles+=(uptime)
  local IFS=,
  local prof="${profiles[*]:-}"
  unset IFS
  cat > "$MON_DIR/.env" <<EOF
# Generated by $SCRIPT_NAME v$SCRIPT_VERSION - safe to edit, then run: ./$SCRIPT_NAME update
COMPOSE_PROFILES=$prof

PROMETHEUS_VERSION=$PROMETHEUS_VERSION
ALERTMANAGER_VERSION=$ALERTMANAGER_VERSION
GRAFANA_VERSION=$GRAFANA_VERSION
NODE_EXPORTER_VERSION=$NODE_EXPORTER_VERSION
BLACKBOX_VERSION=$BLACKBOX_VERSION
CADVISOR_VERSION=$CADVISOR_VERSION

GRAFANA_ADMIN_USER=$GRAFANA_USER
GRAFANA_ADMIN_PASSWORD=$GRAFANA_PASS
GRAFANA_BIND=$GRAFANA_BIND
GRAFANA_PORT=$GRAFANA_PORT
PROM_BIND=$PROM_BIND
PROM_PORT=$PROM_PORT
ALERT_BIND=$ALERT_BIND
ALERT_PORT=$ALERT_PORT
PROMETHEUS_RETENTION=${RETENTION_DAYS}d
EOF
  chmod 600 "$MON_DIR/.env"
}

gen_compose() {
  cat > "$MON_DIR/docker-compose.yml" <<'EOF'
# Generated by monitoring-setup.sh
name: monitoring

services:
  prometheus:
    image: prom/prometheus:${PROMETHEUS_VERSION}
    container_name: prometheus
    restart: unless-stopped
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=${PROMETHEUS_RETENTION}
      - --web.enable-lifecycle
    volumes:
      - ./prometheus:/etc/prometheus:ro
      - prometheus_data:/prometheus
    ports:
      - "${PROM_BIND}:${PROM_PORT}:9090"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks: [monitoring]

  alertmanager:
    image: prom/alertmanager:${ALERTMANAGER_VERSION}
    container_name: alertmanager
    restart: unless-stopped
    command:
      - --config.file=/etc/alertmanager/alertmanager.yml
      - --storage.path=/alertmanager
    volumes:
      - ./alertmanager:/etc/alertmanager:ro
      - alertmanager_data:/alertmanager
    ports:
      - "${ALERT_BIND}:${ALERT_PORT}:9093"
    networks: [monitoring]

  grafana:
    image: grafana/grafana:${GRAFANA_VERSION}
    container_name: grafana
    restart: unless-stopped
    depends_on: [prometheus]
    environment:
      - GF_SECURITY_ADMIN_USER=${GRAFANA_ADMIN_USER}
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_ANALYTICS_REPORTING_ENABLED=false
      - GF_ANALYTICS_CHECK_FOR_UPDATES=false
      - GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/server-overview.json
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
    ports:
      - "${GRAFANA_BIND}:${GRAFANA_PORT}:3000"
    networks: [monitoring]

  node-exporter:
    image: prom/node-exporter:${NODE_EXPORTER_VERSION}
    container_name: node-exporter
    profiles: [node]
    restart: unless-stopped
    network_mode: host
    pid: host
    command:
      - --path.rootfs=/host
      - --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)
    volumes:
      - /:/host:ro,rslave

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:${CADVISOR_VERSION}
    container_name: cadvisor
    profiles: [containers]
    restart: unless-stopped
    privileged: true
    command:
      - --docker_only=true
      - --housekeeping_interval=30s
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
    networks: [monitoring]

  blackbox:
    image: prom/blackbox-exporter:${BLACKBOX_VERSION}
    container_name: blackbox
    profiles: [uptime]
    restart: unless-stopped
    command:
      - --config.file=/etc/blackbox/blackbox.yml
    volumes:
      - ./blackbox:/etc/blackbox:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks: [monitoring]

networks:
  monitoring:
    driver: bridge

volumes:
  prometheus_data:
  alertmanager_data:
  grafana_data:
EOF
}

gen_prometheus() {
  mkdir -p "$MON_DIR/prometheus/targets" "$MON_DIR/prometheus/alerts"
  local f="$MON_DIR/prometheus/prometheus.yml"

  cat > "$f" <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

rule_files:
  - /etc/prometheus/alerts/*.yml

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: alertmanager
    static_configs:
      - targets: ['alertmanager:9093']

  # Servers (Node Exporter) - edit with: ./monitoring-setup.sh add-node <ip> <name>
  - job_name: node
    file_sd_configs:
      - files: ['/etc/prometheus/targets/nodes.yml']
        refresh_interval: 30s

  # Your applications (/metrics) - edit with: ./monitoring-setup.sh add-app <host:port> <name>
  - job_name: apps
    file_sd_configs:
      - files: ['/etc/prometheus/targets/apps.yml']
        refresh_interval: 30s
EOF

  if [ "$ENABLE_CONTAINERS" = true ]; then
    cat >> "$f" <<'EOF'

  - job_name: cadvisor
    static_configs:
      - targets: ['cadvisor:8080']
EOF
  fi

  if [ "$ENABLE_UPTIME" = true ]; then
    cat >> "$f" <<'EOF'

  # Website / URL checks - ./monitoring-setup.sh add-url <https://...> <name>
  - job_name: blackbox-http
    metrics_path: /probe
    params:
      module: [http_2xx]
    file_sd_configs:
      - files: ['/etc/prometheus/targets/http-endpoints.yml']
        refresh_interval: 30s
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115

  # TCP port checks - ./monitoring-setup.sh add-tcp <host:port> <name>
  - job_name: blackbox-tcp
    metrics_path: /probe
    params:
      module: [tcp_connect]
    file_sd_configs:
      - files: ['/etc/prometheus/targets/tcp-endpoints.yml']
        refresh_interval: 30s
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115
EOF
  fi

  # Target files: created only if missing, so your targets survive re-runs
  local t
  for t in apps http-endpoints tcp-endpoints; do
    [ -f "$MON_DIR/prometheus/targets/$t.yml" ] || echo "[]" > "$MON_DIR/prometheus/targets/$t.yml"
  done
  if [ ! -f "$MON_DIR/prometheus/targets/nodes.yml" ]; then
    if [ "$ENABLE_NODE_TARGET" = true ]; then
      local hn
      hn="$(hostname -s 2>/dev/null | sed 's/[^A-Za-z0-9._-]/_/g')"
      cat > "$MON_DIR/prometheus/targets/nodes.yml" <<EOF
- targets: ['host.docker.internal:9100']
  labels:
    instance: ${hn:-monitoring-host}
EOF
    else
      echo "[]" > "$MON_DIR/prometheus/targets/nodes.yml"
    fi
  fi
  chmod 644 "$MON_DIR"/prometheus/targets/*.yml
}

gen_blackbox() {
  mkdir -p "$MON_DIR/blackbox"
  cat > "$MON_DIR/blackbox/blackbox.yml" <<'EOF'
modules:
  http_2xx:
    prober: http
    timeout: 10s
    http:
      method: GET
      follow_redirects: true
      preferred_ip_protocol: ip4
      ip_protocol_fallback: false
  tcp_connect:
    prober: tcp
    timeout: 5s
    tcp:
      preferred_ip_protocol: ip4
EOF
}

gen_alert_rules() {
  mkdir -p "$MON_DIR/prometheus/alerts"
  cat > "$MON_DIR/prometheus/alerts/server.yml" <<'EOF'
groups:
  - name: server
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.job }} target {{ $labels.instance }} is DOWN"

      - alert: HighCpuUsage
        expr: 100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High CPU on {{ $labels.instance }}: {{ $value | printf \"%.0f\" }}%"

      - alert: HighMemoryUsage
        expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory on {{ $labels.instance }}: {{ $value | printf \"%.0f\" }}%"

      - alert: DiskSpaceLow
        expr: (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|rootfs|ramfs|devtmpfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|rootfs|ramfs|devtmpfs"}) * 100 < 15
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Disk {{ $labels.mountpoint }} on {{ $labels.instance }} has only {{ $value | printf \"%.0f\" }}% free"

      - alert: DiskSpaceCritical
        expr: (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|rootfs|ramfs|devtmpfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|rootfs|ramfs|devtmpfs"}) * 100 < 5
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Disk {{ $labels.mountpoint }} on {{ $labels.instance }} is almost FULL ({{ $value | printf \"%.0f\" }}% free)"

      - alert: HighLoad
        expr: node_load5 / on (instance) count by (instance) (node_cpu_seconds_total{mode="idle"}) > 2
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "High load average on {{ $labels.instance }}"
EOF

  cat > "$MON_DIR/prometheus/alerts/app.yml" <<'EOF'
# Application alerts - these assume the metric names used in the README examples:
#   http_requests_total{method,endpoint,status}  and  http_request_duration_seconds_bucket
# If your app uses different names, edit the expressions below.
groups:
  - name: application
    rules:
      - alert: AppHighErrorRate
        expr: sum by (instance) (rate(http_requests_total{status=~"5.."}[5m])) / sum by (instance) (rate(http_requests_total[5m])) > 0.05
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "More than 5% of requests fail (5xx) on {{ $labels.instance }}"

      - alert: AppHighLatencyP95
        expr: histogram_quantile(0.95, sum by (instance, le) (rate(http_request_duration_seconds_bucket[5m]))) > 1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "p95 latency above 1s on {{ $labels.instance }}"
EOF

  if [ "$ENABLE_UPTIME" = true ]; then
    cat > "$MON_DIR/prometheus/alerts/uptime.yml" <<'EOF'
groups:
  - name: uptime
    rules:
      - alert: EndpointDown
        expr: probe_success == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Endpoint {{ $labels.instance }} is not reachable"

      - alert: SlowResponse
        expr: probe_duration_seconds > 3
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }} is responding slowly ({{ $value | printf \"%.1f\" }}s)"

      - alert: SslCertExpiringSoon
        expr: (probe_ssl_earliest_cert_expiry - time()) / 86400 < 14
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "SSL certificate for {{ $labels.instance }} expires in {{ $value | printf \"%.0f\" }} days"
EOF
  else
    rm -f "$MON_DIR/prometheus/alerts/uptime.yml"
  fi
  chmod 644 "$MON_DIR"/prometheus/alerts/*.yml
}

gen_alertmanager() {
  mkdir -p "$MON_DIR/alertmanager"
  local f="$MON_DIR/alertmanager/alertmanager.yml"
  cat > "$f" <<'EOF'
global:
  resolve_timeout: 5m

route:
  receiver: default
  group_by: ['alertname', 'instance']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

inhibit_rules:
  - source_matchers: ['severity="critical"']
    target_matchers: ['severity="warning"']
    equal: ['alertname', 'instance']

receivers:
  - name: default
EOF
  case "$ALERT_CHANNEL" in
    slack)
      cat >> "$f" <<EOF
    slack_configs:
      - api_url: '$(yaml_sq "$SLACK_URL")'
        send_resolved: true
        title: '[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}'
        text: >-
          {{ range .Alerts }}{{ .Annotations.summary }} {{ end }}
EOF
      ;;
    telegram)
      cat >> "$f" <<EOF
    telegram_configs:
      - bot_token: '$(yaml_sq "$TG_TOKEN")'
        chat_id: $TG_CHAT
        send_resolved: true
EOF
      ;;
    email)
      cat >> "$f" <<EOF
    email_configs:
      - to: '$(yaml_sq "$SMTP_TO")'
        from: '$(yaml_sq "$SMTP_FROM")'
        smarthost: '$(yaml_sq "$SMTP_HOST")'
        auth_username: '$(yaml_sq "$SMTP_USER")'
        auth_password: '$(yaml_sq "$SMTP_PASS")'
        send_resolved: true
EOF
      ;;
  esac
  chmod 644 "$f"   # container user ('nobody') must be able to read it
}

# ----- Grafana provisioning + dashboards -----
DS='{"type":"prometheus","uid":"prometheus"}'

gen_grafana_provisioning() {
  mkdir -p "$MON_DIR/grafana/provisioning/datasources" \
           "$MON_DIR/grafana/provisioning/dashboards" \
           "$MON_DIR/grafana/dashboards"
  cat > "$MON_DIR/grafana/provisioning/datasources/prometheus.yml" <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
EOF
  cat > "$MON_DIR/grafana/provisioning/dashboards/dashboards.yml" <<'EOF'
apiVersion: 1
providers:
  - name: devops
    orgId: 1
    folder: DevOps
    type: file
    disableDeletion: false
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
EOF
}

# JSON helpers. PromQL is written with "double quotes"; '@I' expands to instance=~"$instance"
esc() {
  local s="$1"
  s="${s//@I/instance=~\"\$instance\"}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}
pj() { local IFS=,; printf '%s' "$*"; }

panel_ts() {  # id title x y w h unit expr legend [expr legend ...]
  local id="$1" title="$2" x="$3" y="$4" w="$5" h="$6" unit="$7"; shift 7
  local refs=(A B C D E F) i=0 t=()
  while [ $# -ge 2 ]; do
    t+=("{\"refId\":\"${refs[$i]}\",\"expr\":\"$(esc "$1")\",\"legendFormat\":\"$(esc "$2")\",\"datasource\":$DS}")
    shift 2; i=$((i + 1))
  done
  printf '{"id":%s,"type":"timeseries","title":"%s","datasource":%s,"gridPos":{"x":%s,"y":%s,"w":%s,"h":%s},"fieldConfig":{"defaults":{"unit":"%s","custom":{"lineWidth":1,"fillOpacity":10,"showPoints":"never"}},"overrides":[]},"options":{"legend":{"displayMode":"list","placement":"bottom","showLegend":true},"tooltip":{"mode":"multi","sort":"desc"}},"targets":[%s]}' \
    "$id" "$(esc "$title")" "$DS" "$x" "$y" "$w" "$h" "$unit" "$(pj "${t[@]}")"
}

panel_stat() {  # id title x y w h unit expr legend [warn crit]
  local id="$1" title="$2" x="$3" y="$4" w="$5" h="$6" unit="$7" expr="$8" legend="$9"
  local warn_v="${10:-}" crit_v="${11:-}" steps
  if [ -z "$warn_v" ]; then
    steps='[{"color":"blue","value":null}]'
  else
    steps="[{\"color\":\"green\",\"value\":null},{\"color\":\"orange\",\"value\":$warn_v},{\"color\":\"red\",\"value\":$crit_v}]"
  fi
  printf '{"id":%s,"type":"stat","title":"%s","datasource":%s,"gridPos":{"x":%s,"y":%s,"w":%s,"h":%s},"fieldConfig":{"defaults":{"unit":"%s","decimals":1,"thresholds":{"mode":"absolute","steps":%s}},"overrides":[]},"options":{"reduceOptions":{"calcs":["lastNotNull"],"fields":"","values":false},"colorMode":"value","graphMode":"area","textMode":"auto","orientation":"auto"},"targets":[{"refId":"A","expr":"%s","legendFormat":"%s","datasource":%s}]}' \
    "$id" "$(esc "$title")" "$DS" "$x" "$y" "$w" "$h" "$unit" "$steps" "$(esc "$expr")" "$(esc "$legend")" "$DS"
}

panel_updown() {  # id title x y w h expr legend
  printf '{"id":%s,"type":"stat","title":"%s","datasource":%s,"gridPos":{"x":%s,"y":%s,"w":%s,"h":%s},"fieldConfig":{"defaults":{"mappings":[{"type":"value","options":{"0":{"text":"DOWN","color":"red","index":0},"1":{"text":"UP","color":"green","index":1}}}],"thresholds":{"mode":"absolute","steps":[{"color":"red","value":null},{"color":"green","value":1}]}},"overrides":[]},"options":{"reduceOptions":{"calcs":["lastNotNull"],"fields":"","values":false},"colorMode":"background","graphMode":"none","textMode":"auto","orientation":"auto"},"targets":[{"refId":"A","expr":"%s","legendFormat":"%s","datasource":%s}]}' \
    "$1" "$(esc "$2")" "$DS" "$3" "$4" "$5" "$6" "$(esc "$7")" "$(esc "$8")" "$DS"
}

tpl_instance() {  # metric used to list instances
  printf '{"name":"instance","label":"Instance","type":"query","datasource":%s,"query":"label_values(%s, instance)","definition":"label_values(%s, instance)","refresh":2,"includeAll":true,"multi":true,"allValue":".*","sort":1,"current":{"selected":true,"text":["All"],"value":["$__all"]}}' \
    "$DS" "$1" "$1"
}

write_dashboard() {  # file uid title templating panels...
  local file="$1" uid="$2" title="$3" tpl="$4"; shift 4
  printf '{"uid":"%s","title":"%s","tags":["devops","auto"],"timezone":"browser","editable":true,"schemaVersion":39,"version":1,"refresh":"30s","time":{"from":"now-3h","to":"now"},"templating":{"list":[%s]},"annotations":{"list":[]},"panels":[%s]}\n' \
    "$uid" "$title" "$tpl" "$(pj "$@")" > "$file"
}

gen_dashboards() {
  local d="$MON_DIR/grafana/dashboards"
  gen_grafana_provisioning

  # ---------- 1. Server Overview ----------
  write_dashboard "$d/server-overview.json" "server-overview" "Server Overview" "$(tpl_instance node_uname_info)" \
    "$(panel_stat 1 'CPU usage' 0 0 4 4 percent '100 - (avg(rate(node_cpu_seconds_total{mode="idle",@I}[5m])) * 100)' '' 70 90)" \
    "$(panel_stat 2 'Memory usage' 4 0 4 4 percent '(1 - sum(node_memory_MemAvailable_bytes{@I}) / sum(node_memory_MemTotal_bytes{@I})) * 100' '' 75 90)" \
    "$(panel_stat 3 'Disk usage (/)' 8 0 4 4 percent '(1 - sum(node_filesystem_avail_bytes{@I,mountpoint="/",fstype!~"tmpfs|overlay|squashfs|rootfs"}) / sum(node_filesystem_size_bytes{@I,mountpoint="/",fstype!~"tmpfs|overlay|squashfs|rootfs"})) * 100' '' 75 90)" \
    "$(panel_stat 4 'Uptime (shortest)' 12 0 4 4 s 'min(time() - node_boot_time_seconds{@I})' '')" \
    "$(panel_stat 5 'Load average (1m)' 16 0 4 4 short 'avg(node_load1{@I})' '')" \
    "$(panel_stat 6 'Servers up' 20 0 4 4 none 'count(up{job="node"} == 1)' '')" \
    "$(panel_ts 7 'CPU usage %' 0 4 12 8 percent '100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle",@I}[5m])) * 100)' '{{instance}}')" \
    "$(panel_ts 8 'Memory usage %' 12 4 12 8 percent '(1 - node_memory_MemAvailable_bytes{@I} / node_memory_MemTotal_bytes{@I}) * 100' '{{instance}}')" \
    "$(panel_ts 9 'Network traffic' 0 12 12 8 Bps 'sum by (instance) (rate(node_network_receive_bytes_total{@I,device!~"lo|docker.*|veth.*|br-.*"}[5m]))' '{{instance}} in' 'sum by (instance) (rate(node_network_transmit_bytes_total{@I,device!~"lo|docker.*|veth.*|br-.*"}[5m]))' '{{instance}} out')" \
    "$(panel_ts 10 'Disk usage %' 12 12 12 8 percent '(1 - node_filesystem_avail_bytes{@I,fstype!~"tmpfs|overlay|squashfs|rootfs|ramfs|devtmpfs"} / node_filesystem_size_bytes{@I,fstype!~"tmpfs|overlay|squashfs|rootfs|ramfs|devtmpfs"}) * 100' '{{instance}} {{mountpoint}}')" \
    "$(panel_ts 11 'Disk I/O' 0 20 12 8 Bps 'sum by (instance) (rate(node_disk_read_bytes_total{@I}[5m]))' '{{instance}} read' 'sum by (instance) (rate(node_disk_written_bytes_total{@I}[5m]))' '{{instance}} write')" \
    "$(panel_ts 12 'Load average' 12 20 12 8 short 'node_load1{@I}' '{{instance}} 1m' 'node_load5{@I}' '{{instance}} 5m' 'node_load15{@I}' '{{instance}} 15m')"

  # ---------- 2. Containers (cAdvisor) ----------
  if [ "$ENABLE_CONTAINERS" = true ]; then
    write_dashboard "$d/containers.json" "containers" "Docker Containers" "" \
      "$(panel_stat 1 'Running containers' 0 0 6 4 none 'count(container_last_seen{name!=""})' '')" \
      "$(panel_ts 2 'CPU usage per container' 0 4 12 8 percent 'sum by (name) (rate(container_cpu_usage_seconds_total{name!=""}[5m])) * 100' '{{name}}')" \
      "$(panel_ts 3 'Memory per container' 12 4 12 8 bytes 'sum by (name) (container_memory_working_set_bytes{name!=""})' '{{name}}')" \
      "$(panel_ts 4 'Network receive' 0 12 12 8 Bps 'sum by (name) (rate(container_network_receive_bytes_total{name!=""}[5m]))' '{{name}}')" \
      "$(panel_ts 5 'Network transmit' 12 12 12 8 Bps 'sum by (name) (rate(container_network_transmit_bytes_total{name!=""}[5m]))' '{{name}}')"
  else
    rm -f "$d/containers.json"
  fi

  # ---------- 3. Application (HTTP) ----------
  write_dashboard "$d/application.json" "application" "Application (HTTP)" "$(tpl_instance http_requests_total)" \
    "$(panel_stat 1 'Requests / sec' 0 0 6 4 reqps 'sum(rate(http_requests_total{@I}[5m]))' '')" \
    "$(panel_stat 2 'Error rate (5xx)' 6 0 6 4 percent 'sum(rate(http_requests_total{@I,status=~"5.."}[5m])) / sum(rate(http_requests_total{@I}[5m])) * 100' '' 1 5)" \
    "$(panel_stat 3 'p95 latency' 12 0 6 4 s 'histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{@I}[5m])))' '' 0.5 1)" \
    "$(panel_updown 4 'App targets' 18 0 6 4 'up{job="apps"}' '{{instance}}')" \
    "$(panel_ts 5 'Requests by status' 0 4 12 8 reqps 'sum by (status) (rate(http_requests_total{@I}[5m]))' '{{status}}')" \
    "$(panel_ts 6 'Requests by endpoint' 12 4 12 8 reqps 'sum by (endpoint) (rate(http_requests_total{@I}[5m]))' '{{endpoint}}')" \
    "$(panel_ts 7 'Latency (p50 / p95 / p99)' 0 12 12 8 s 'histogram_quantile(0.50, sum by (le) (rate(http_request_duration_seconds_bucket{@I}[5m])))' 'p50' 'histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{@I}[5m])))' 'p95' 'histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{@I}[5m])))' 'p99')" \
    "$(panel_ts 8 '5xx errors / sec' 12 12 12 8 reqps 'sum by (instance) (rate(http_requests_total{@I,status=~"5.."}[5m]))' '{{instance}}')"

  # ---------- 4. Uptime (Blackbox) ----------
  if [ "$ENABLE_UPTIME" = true ]; then
    write_dashboard "$d/uptime.json" "uptime" "Uptime (Websites & Ports)" "" \
      "$(panel_updown 1 'Websites / URLs' 0 0 12 5 'probe_success{job="blackbox-http"}' '{{instance}}')" \
      "$(panel_updown 2 'TCP ports' 12 0 12 5 'probe_success{job="blackbox-tcp"}' '{{instance}}')" \
      "$(panel_ts 3 'Response time' 0 5 12 8 s 'probe_duration_seconds{job="blackbox-http"}' '{{instance}}')" \
      "$(panel_stat 4 'SSL certificate days left' 12 5 12 8 d '(probe_ssl_earliest_cert_expiry - time()) / 86400' '{{instance}}' )" \
      "$(panel_stat 5 'HTTP status code' 0 13 12 5 none 'probe_http_status_code' '{{instance}}')"
  else
    rm -f "$d/uptime.json"
  fi
  chmod 644 "$d"/*.json
}

generate_all() {
  section "Generating configuration in $MON_DIR"
  mkdir -p "$MON_DIR"
  gen_env
  gen_compose
  gen_prometheus
  gen_alert_rules
  gen_alertmanager
  [ "$ENABLE_UPTIME" = true ] && gen_blackbox
  gen_dashboards
  ok "Config files written."
}

# ------------------------------ validation -----------------------------------
validate_stack() {
  section "Validating configuration"
  if compose config -q; then ok "docker-compose.yml is valid"; else err "docker-compose.yml is invalid"; return 1; fi

  if "${DOCKER[@]}" run --rm --entrypoint promtool \
        -v "$MON_DIR/prometheus:/etc/prometheus:ro" \
        "prom/prometheus:${PROMETHEUS_VERSION}" check config /etc/prometheus/prometheus.yml; then
    ok "Prometheus config + alert rules are valid"
  else
    err "Prometheus config check FAILED (see output above)"; return 1
  fi

  if "${DOCKER[@]}" run --rm --entrypoint amtool \
        -v "$MON_DIR/alertmanager:/etc/alertmanager:ro" \
        "prom/alertmanager:${ALERTMANAGER_VERSION}" check-config /etc/alertmanager/alertmanager.yml; then
    ok "Alertmanager config is valid"
  else
    err "Alertmanager config check FAILED (see output above)"; return 1
  fi

  if has_cmd jq; then
    local j
    for j in "$MON_DIR"/grafana/dashboards/*.json; do
      jq empty "$j" 2>/dev/null || { err "Invalid dashboard JSON: $j"; return 1; }
    done
    ok "Grafana dashboards are valid JSON"
  fi
  return 0
}

# ------------------------------ run helpers ----------------------------------
wait_http() {  # name url timeout_seconds
  local name="$1" url="$2" max="${3:-90}" i=0
  printf "  waiting for %s " "$name"
  while [ "$i" -lt "$max" ]; do
    if curl -fsS -m 3 -o /dev/null "$url" 2>/dev/null; then
      printf " %sready%s\n" "$GREEN" "$NC"; return 0
    fi
    printf "."; sleep 2; i=$((i + 2))
  done
  printf " %sTIMEOUT%s\n" "$RED" "$NC"; return 1
}

prom_query() {
  curl -fsS -m 5 -G "http://127.0.0.1:${PROM_PORT}/api/v1/query" --data-urlencode "query=$1" 2>/dev/null \
    | sed -n 's/.*"value":\[[0-9.]*,"\([0-9.eE+-]*\)"\].*/\1/p' | head -n1
}

start_stack() {
  section "Starting containers"
  if ! compose up -d --remove-orphans; then
    err "'docker compose up' failed."; compose ps; return 1
  fi
  wait_http "Prometheus"   "http://127.0.0.1:${PROM_PORT}/-/ready"    90  || { compose logs --tail=30 prometheus;   return 1; }
  wait_http "Alertmanager" "http://127.0.0.1:${ALERT_PORT}/-/ready"   60  || { compose logs --tail=30 alertmanager; return 1; }
  wait_http "Grafana"      "http://127.0.0.1:${GRAFANA_PORT}/api/health" 120 || { compose logs --tail=30 grafana;    return 1; }
  return 0
}

check_targets() {
  info "Giving exporters a few seconds to be scraped..."
  sleep 20
  local up down
  up="$(prom_query 'count(up == 1) or vector(0)')"
  down="$(prom_query 'count(up == 0) or vector(0)')"
  ok "Targets UP: ${up:-?}   DOWN: ${down:-?}"
  if [ "${down:-0}" != "0" ] && [ -n "${down:-}" ]; then
    warn "Some targets are down. Run '$SCRIPT_NAME status' or open Prometheus -> Status -> Targets."
  fi
}

print_urls() {
  local ip; ip="$(public_ip)"
  section "Access"
  echo "  Grafana       : http://${ip}:${GRAFANA_PORT}"
  if [ "$PROM_BIND" = "127.0.0.1" ]; then
    echo "  Prometheus    : http://localhost:${PROM_PORT}   (localhost only - use an SSH tunnel)"
    echo "  Alertmanager  : http://localhost:${ALERT_PORT}   (localhost only - use an SSH tunnel)"
    echo "  SSH tunnel    : ssh -L ${PROM_PORT}:localhost:${PROM_PORT} -L ${ALERT_PORT}:localhost:${ALERT_PORT} <user>@${ip}"
  else
    echo "  Prometheus    : http://${ip}:${PROM_PORT}"
    echo "  Alertmanager  : http://${ip}:${ALERT_PORT}"
  fi
}

# ------------------------------ SERVER wizard --------------------------------
ask_alert_channel() {
  $ASSUME_YES && { ALERT_CHANNEL="none"; return 0; }
  echo
  echo "  Where should alerts be sent?"
  echo "    1) Nowhere (just view them in Grafana / Alertmanager)"
  echo "    2) Slack (incoming webhook)"
  echo "    3) Telegram bot"
  echo "    4) Email (SMTP)"
  local c
  while true; do
    ask_text "Choice" "1" c
    case "$c" in
      1) ALERT_CHANNEL="none"; return 0 ;;
      2) ALERT_CHANNEL="slack"
         while true; do
           ask_text "Slack webhook URL (https://hooks.slack.com/...)" "" SLACK_URL
           valid_url "$SLACK_URL" && break; warn "That doesn't look like a valid URL."
         done
         return 0 ;;
      3) ALERT_CHANNEL="telegram"
         while true; do
           ask_text "Telegram bot token (123456:ABC...)" "" TG_TOKEN
           [[ "$TG_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] && break; warn "Invalid token format."
         done
         while true; do
           ask_text "Telegram chat ID (number, groups start with -)" "" TG_CHAT
           [[ "$TG_CHAT" =~ ^-?[0-9]+$ ]] && break; warn "Chat ID must be a number."
         done
         return 0 ;;
      4) ALERT_CHANNEL="email"
         ask_text "Send alerts TO (email)" "" SMTP_TO
         ask_text "Send alerts FROM (email)" "$SMTP_TO" SMTP_FROM
         ask_text "SMTP server:port (e.g. smtp.gmail.com:587)" "smtp.gmail.com:587" SMTP_HOST
         ask_text "SMTP username" "$SMTP_FROM" SMTP_USER
         read -r -s -u 3 -p "${CYAN}?${NC} SMTP password / app password: " SMTP_PASS; echo
         if [ -z "$SMTP_TO" ] || [ -z "$SMTP_HOST" ]; then warn "Email details incomplete."; continue; fi
         return 0 ;;
      *) warn "Enter 1, 2, 3 or 4." ;;
    esac
  done
}

ask_server_options() {
  section "Monitoring server options"
  ask_text "Install directory" "$MON_DIR" MON_DIR
  MON_DIR="${MON_DIR/#\~/$HOME}"

  # Re-run: keep existing values (password, versions, retention)
  load_env
  [ -n "${GRAFANA_ADMIN_PASSWORD:-}" ] && GRAFANA_PASS="$GRAFANA_ADMIN_PASSWORD"
  [ -n "${GRAFANA_ADMIN_USER:-}" ]     && GRAFANA_USER="$GRAFANA_ADMIN_USER"

  if ask_yn "Monitor Docker containers (cAdvisor)?" y; then ENABLE_CONTAINERS=true; else ENABLE_CONTAINERS=false; fi
  if ask_yn "Enable website / URL / port uptime checks (Blackbox)?" y; then ENABLE_UPTIME=true; else ENABLE_UPTIME=false; fi

  while true; do
    ask_text "Grafana admin username" "$GRAFANA_USER" GRAFANA_USER
    valid_name "$GRAFANA_USER" && break; warn "Use letters, digits, . _ - only."
  done

  if [ -n "$GRAFANA_PASS" ]; then
    info "Keeping the existing Grafana password from $MON_DIR/.env"
  elif ask_yn "Generate a strong Grafana password automatically?" y; then
    GRAFANA_PASS="$(gen_password)"
  else
    while true; do
      read -r -s -u 3 -p "${CYAN}?${NC} Grafana password (8-64 chars: letters digits _ @ % + = . -): " GRAFANA_PASS; echo
      valid_password "$GRAFANA_PASS" && break
      warn "Password must be 8-64 chars and use only: A-Z a-z 0-9 _ @ % + = . -"
    done
  fi

  if ask_yn "Expose Prometheus & Alertmanager UIs to the network? (No = localhost only, safer)" n; then
    PROM_BIND="0.0.0.0"; ALERT_BIND="0.0.0.0"
  else
    PROM_BIND="127.0.0.1"; ALERT_BIND="127.0.0.1"
  fi

  while true; do
    ask_text "Keep metrics for how many days?" "$RETENTION_DAYS" RETENTION_DAYS
    [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] && [ "$RETENTION_DAYS" -ge 1 ] && break
    warn "Enter a number of days (1 or more)."
  done

  ask_alert_channel
}

check_ports_and_node() {
  section "Checking ports"
  # Existing install of THIS stack: stop it first (data is kept) so its ports are free
  if [ -f "$MON_DIR/docker-compose.yml" ] && ! $DRY_RUN; then
    info "Existing stack found - stopping it for re-configuration (your data is kept)."
    compose down >/dev/null 2>&1 || true
  fi

  if $DRY_RUN; then return 0; fi

  pick_port "Grafana"      "$GRAFANA_PORT" GRAFANA_PORT
  pick_port "Prometheus"   "$PROM_PORT"    PROM_PORT
  pick_port "Alertmanager" "$ALERT_PORT"   ALERT_PORT

  # Node exporter (host metrics) uses host port 9100
  if port_in_use 9100; then
    warn "Port 9100 is already in use (probably an existing node_exporter on this host)."
    if ask_yn "Use that existing exporter for this host's metrics?" y; then
      ENABLE_NODE_CONTAINER=false; ENABLE_NODE_TARGET=true
    else
      ENABLE_NODE_CONTAINER=false; ENABLE_NODE_TARGET=false
      warn "This host will not be monitored. Add it later with: $SCRIPT_NAME add-node"
    fi
  fi
  ok "Ports are free."
}

install_server() {
  init_tty
  section "Monitoring SERVER setup"
  ask_server_options

  section "Summary"
  echo "  Directory     : $MON_DIR"
  echo "  Containers    : $ENABLE_CONTAINERS (cAdvisor)"
  echo "  Uptime checks : $ENABLE_UPTIME (Blackbox)"
  echo "  Grafana user  : $GRAFANA_USER"
  echo "  UIs exposed   : Prometheus/Alertmanager bind = $PROM_BIND"
  echo "  Retention     : ${RETENTION_DAYS} days"
  echo "  Alerts to     : $ALERT_CHANNEL"
  $DRY_RUN && echo "  Mode          : DRY RUN (files only, nothing is started)"
  ask_yn "Proceed?" y || { info "Cancelled. Nothing was changed."; exit 0; }

  if ! $DRY_RUN; then
    ensure_docker
    has_cmd curl || { as_root apt-get install -y curl >/dev/null 2>&1 || die "curl is required."; }
  fi

  check_ports_and_node
  generate_all

  if $DRY_RUN; then
    section "Dry run finished - generated files"
    ( cd "$MON_DIR" && find . -type f | sort )
    return 0
  fi

  validate_stack || die "Validation failed. Fix the error above (files are in $MON_DIR) and re-run."
  start_stack    || die "A service did not become ready. Logs are shown above."
  check_targets

  print_urls
  section "Login"
  echo "  Grafana user     : $GRAFANA_USER"
  echo "  Grafana password : $GRAFANA_PASS      (also saved in $MON_DIR/.env)"
  section "Next steps"
  echo "  1) AWS Security Group: allow TCP ${GRAFANA_PORT} from YOUR IP only."
  echo "  2) Monitor another server : run '$SCRIPT_NAME agent' there, then"
  echo "                              '$SCRIPT_NAME add-node <that-server-private-ip> <name>' here."
  echo "  3) Monitor an application : expose /metrics, then '$SCRIPT_NAME add-app <host:port> <name>'."
  echo "  4) Monitor a website      : '$SCRIPT_NAME add-url https://example.com <name>'."
  echo "  5) Test alerting          : '$SCRIPT_NAME test-alert'"
  ok "Done. Happy monitoring! 📈"
}

# ------------------------------ TARGET management ----------------------------
append_target() {  # file target label_key label_value [extra_label_key extra_label_value]
  local f="$1" tgt="$2" k="$3" v="$4" k2="${5:-}" v2="${6:-}"
  [ -f "$f" ] || echo "[]" > "$f"
  if grep -qF "'${tgt}'" "$f"; then warn "'$tgt' is already in $(basename "$f") - nothing to do."; return 0; fi
  if grep -qx '\[\]' "$f"; then : > "$f"; fi
  {
    printf "%s\n" "- targets: ['${tgt}']"
    printf "%s\n" "  labels:"
    printf "%s\n" "    ${k}: '${v}'"
    if [ -n "$k2" ]; then printf "%s\n" "    ${k2}: '${v2}'"; fi
  } >> "$f"
  ok "Added '$tgt' (${k}=${v}). Prometheus picks it up within ~30 seconds."
}

add_target() {  # kind value [name] [path]
  local kind="$1" val="${2:-}" name="${3:-}" path="${4:-}"
  [ -d "$MON_DIR/prometheus/targets" ] || die "No monitoring stack found in $MON_DIR (use --dir <path>)."
  load_env
  [ -n "$val" ] || die "Usage: $SCRIPT_NAME add-$kind <target> [name]"
  local tdir="$MON_DIR/prometheus/targets"

  case "$kind" in
    node)
      valid_hostport "$val" || die "Invalid target '$val'. Use host or host:port (e.g. 10.0.1.25)."
      [[ "$val" == *:* ]] || val="${val}:9100"
      name="${name:-${val%%:*}}"; valid_name "$name" || die "Invalid name (letters, digits, . _ - only)."
      append_target "$tdir/nodes.yml" "$val" instance "$name"
      info "Make sure the agent is installed there and port 9100 is reachable from this server."
      ;;
    app)
      valid_hostport "$val" && [[ "$val" == *:* ]] || die "Invalid target '$val'. Use host:port (e.g. 10.0.1.30:8000)."
      name="${name:-${val%%:*}-${val##*:}}"; valid_name "$name" || die "Invalid name (letters, digits, . _ - only)."
      if [ -n "$path" ]; then
        case "$path" in /*) : ;; *) die "Metrics path must start with / (e.g. /actuator/prometheus)." ;; esac
        [[ "$path" =~ ^/[A-Za-z0-9._/-]*$ ]] || die "Invalid metrics path."
        append_target "$tdir/apps.yml" "$val" instance "$name" __metrics_path__ "$path"
      else
        append_target "$tdir/apps.yml" "$val" instance "$name"
      fi
      info "App must expose Prometheus metrics (default path /metrics) and listen on 0.0.0.0."
      ;;
    url)
      valid_url "$val" || die "Invalid URL '$val'. It must start with http:// or https://"
      name="${name:-$val}"; case "$name" in *\'*) die "Invalid name." ;; esac
      append_target "$tdir/http-endpoints.yml" "$val" site "$name"
      [ "${COMPOSE_PROFILES:-}" = "${COMPOSE_PROFILES/uptime/}" ] \
        && warn "Uptime checks were not enabled in this install - re-run '$SCRIPT_NAME server' and enable them."
      ;;
    tcp)
      valid_hostport "$val" && [[ "$val" == *:* ]] || die "Invalid target '$val'. Use host:port (e.g. db.internal:5432)."
      name="${name:-$val}"; case "$name" in *\'*) die "Invalid name." ;; esac
      append_target "$tdir/tcp-endpoints.yml" "$val" site "$name"
      [ "${COMPOSE_PROFILES:-}" = "${COMPOSE_PROFILES/uptime/}" ] \
        && warn "Uptime checks were not enabled in this install - re-run '$SCRIPT_NAME server' and enable them."
      ;;
  esac
}

remove_target() {
  local val="${1:-}" f n=0
  [ -n "$val" ] || die "Usage: $SCRIPT_NAME remove <target>   (e.g. 10.0.1.25:9100)"
  [ -d "$MON_DIR/prometheus/targets" ] || die "No monitoring stack found in $MON_DIR."
  for f in "$MON_DIR"/prometheus/targets/*.yml; do
    if grep -qF "'${val}'" "$f"; then
      awk -v pat="'${val}'" '
        function flush() { if (blk != "" && index(blk, pat) == 0) printf "%s", blk; blk = "" }
        /^- targets:/ { flush() }
        { blk = blk $0 "\n" }
        END { flush() }' "$f" > "$f.tmp"
      if [ -s "$f.tmp" ]; then cat "$f.tmp" > "$f"; else echo "[]" > "$f"; fi
      rm -f "$f.tmp"
      n=$((n + 1)); ok "Removed '$val' from $(basename "$f")"
    fi
  done
  [ "$n" -gt 0 ] || warn "Target '$val' not found. Run '$SCRIPT_NAME targets' to list them."
}

list_targets() {
  [ -d "$MON_DIR/prometheus/targets" ] || die "No monitoring stack found in $MON_DIR."
  local f
  for f in "$MON_DIR"/prometheus/targets/*.yml; do
    printf "\n%s%s%s\n" "$BOLD" "$(basename "$f" .yml)" "$NC"
    if grep -qx '\[\]' "$f"; then echo "  (none)"; else grep -E "^- targets:|^    (instance|site):" "$f" | sed 's/^/  /'; fi
  done
  echo
}

# ------------------------------ AGENT (node exporter) ------------------------
install_agent() {
  init_tty
  section "AGENT setup (Node Exporter on this machine)"
  has_cmd systemctl && [ -d /run/systemd/system ] || die "systemd is required for the agent (on WSL enable it in /etc/wsl.conf)."
  has_cmd curl || { as_root apt-get install -y curl >/dev/null 2>&1 || die "curl is required."; }

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx node-exporter \
     || as_root docker ps --format '{{.Names}}' 2>/dev/null | grep -qx node-exporter; then
    ok "This machine already runs the node-exporter container (monitoring server). No agent needed."
    return 0
  fi

  local arch ver base file tmp
  case "$(uname -m)" in
    x86_64)        arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
  ver="${NODE_EXPORTER_VERSION#v}"

  if systemctl is-active --quiet node_exporter 2>/dev/null; then
    ok "node_exporter service is already running."
  else
    if port_in_use 9100; then die "Port 9100 is already in use by another process."; fi
    base="https://github.com/prometheus/node_exporter/releases/download/v${ver}"
    file="node_exporter-${ver}.linux-${arch}.tar.gz"
    tmp="$(mktemp -d)"
    info "Downloading node_exporter v${ver} (${arch})..."
    curl -fsSL -o "$tmp/$file" "$base/$file"            || { rm -rf "$tmp"; die "Download failed (check internet access)."; }
    curl -fsSL -o "$tmp/sha256sums.txt" "$base/sha256sums.txt" || { rm -rf "$tmp"; die "Could not download checksums."; }
    ( cd "$tmp" && grep " ${file}\$" sha256sums.txt | sha256sum -c - >/dev/null ) \
      || { rm -rf "$tmp"; die "Checksum verification FAILED - aborting."; }
    ok "Checksum verified."
    tar -xzf "$tmp/$file" -C "$tmp"
    as_root install -m 0755 "$tmp/node_exporter-${ver}.linux-${arch}/node_exporter" /usr/local/bin/node_exporter
    rm -rf "$tmp"

    id node_exporter >/dev/null 2>&1 \
      || as_root useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter
    as_root tee /etc/systemd/system/node_exporter.service >/dev/null <<'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9100
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    as_root systemctl daemon-reload
    as_root systemctl enable --now node_exporter || die "Could not start node_exporter. See: journalctl -u node_exporter"
  fi

  wait_http "node_exporter" "http://127.0.0.1:9100/metrics" 30 \
    || die "node_exporter did not respond. See: sudo journalctl -u node_exporter -n 30"

  # Optional host firewall
  if has_cmd ufw && as_root ufw status 2>/dev/null | grep -q "Status: active"; then
    local mon_ip
    ask_text "ufw is active. Monitoring server IP allowed to reach port 9100 (blank = skip)" "" mon_ip
    if [[ "$mon_ip" =~ ^[0-9a-fA-F:.]+(/[0-9]+)?$ ]]; then
      as_root ufw allow from "$mon_ip" to any port 9100 proto tcp && ok "ufw rule added for $mon_ip"
    fi
  fi

  local pip; pip="$(private_ip)"
  section "Agent ready"
  echo "  Metrics URL : http://${pip:-<this-server-ip>}:9100/metrics"
  echo
  echo "  Now, on the MONITORING server run:"
  echo "      ./$SCRIPT_NAME add-node ${pip:-<this-server-private-ip>} $(hostname -s)"
  echo
  echo "  AWS Security Group of THIS server: allow TCP 9100 only from the monitoring"
  echo "  server's security group / private IP. Do NOT open 9100 to the internet."
  ok "Done."
}

remove_agent() {
  info "Removing node_exporter agent..."
  as_root systemctl disable --now node_exporter 2>/dev/null || true
  as_root rm -f /etc/systemd/system/node_exporter.service /usr/local/bin/node_exporter
  as_root systemctl daemon-reload 2>/dev/null || true
  id node_exporter >/dev/null 2>&1 && as_root userdel node_exporter 2>/dev/null
  ok "Agent removed."
}

# ------------------------------ DAY-2 commands -------------------------------
cmd_status() {
  require_stack
  section "Containers"
  compose ps
  section "Targets"
  local up down
  up="$(prom_query 'count(up == 1) or vector(0)')"
  down="$(prom_query 'count(up == 0) or vector(0)')"
  echo "  UP: ${up:-?}   DOWN: ${down:-?}"
  list_targets
  print_urls
}

cmd_logs()    { require_stack; compose logs --tail=100 -f "$@"; }
cmd_restart() { require_stack; compose restart; ok "Restarted."; }
cmd_down()    { require_stack; compose down; ok "Stack stopped (data kept). Start again with: $SCRIPT_NAME update"; }

cmd_update() {
  require_stack
  section "Updating images"
  compose pull && compose up -d --remove-orphans && compose ps
  ok "Updated. (Versions are pinned in $MON_DIR/.env)"
}

cmd_validate() {
  require_stack
  validate_stack && ok "Everything is valid." || exit 1
}

cmd_test_alert() {
  require_stack
  local body='[{"labels":{"alertname":"TestAlert","severity":"warning","instance":"manual-test"},"annotations":{"summary":"This is a TEST alert sent by monitoring-setup.sh"}}]'
  if curl -fsS -m 5 -X POST "http://127.0.0.1:${ALERT_PORT}/api/v2/alerts" \
        -H 'Content-Type: application/json' -d "$body" >/dev/null; then
    ok "Test alert sent. It appears in Alertmanager now and reaches your channel after ~30s (group_wait)."
  else
    die "Could not reach Alertmanager on port ${ALERT_PORT}. Is the stack running? ($SCRIPT_NAME status)"
  fi
}

cmd_grafana_password() {
  init_tty
  require_stack
  local pw
  while true; do
    read -r -s -u 3 -p "${CYAN}?${NC} New Grafana password (8-64 chars: letters digits _ @ % + = . -): " pw; echo
    valid_password "$pw" && break
    warn "Use 8-64 chars from: A-Z a-z 0-9 _ @ % + = . -"
  done
  if "${DOCKER[@]}" exec grafana grafana cli admin reset-admin-password "$pw" >/dev/null 2>&1; then
    sed -i "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=${pw}|" "$MON_DIR/.env"
    ok "Grafana admin password changed."
  else
    die "Could not change the password. Is the grafana container running?"
  fi
}

cmd_uninstall() {
  init_tty
  require_stack
  warn "This stops the stack and DELETES all metrics & Grafana data (docker volumes)."
  local ans
  ask_text "Type 'yes' to continue" "no" ans
  [ "$ans" = "yes" ] || { info "Cancelled."; return 0; }
  compose down -v
  ok "Stack and data removed. Config files remain in $MON_DIR (delete the folder if you want)."
}

# ------------------------------ menu / usage ---------------------------------
usage() {
  cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} - server + application monitoring (Prometheus, Grafana, Alertmanager)

USAGE
  ./${SCRIPT_NAME} [options] [command]

INSTALL
  server                         Install the monitoring server (wizard)
  agent                          Install Node Exporter on THIS machine (to be monitored)
  remove-agent                   Remove the agent from this machine

ADD / REMOVE WHAT YOU MONITOR (no restart needed)
  add-node <ip[:9100]> [name]    A server running the agent
  add-app  <host:port> [name] [/metrics-path]    An application exposing Prometheus metrics
  add-url  <https://...> [name]  Website / API health check
  add-tcp  <host:port> [name]    TCP port check (database, SSH, ...)
  remove   <target>              Remove any target
  targets                        List all targets

OPERATE
  status | logs [service] | restart | update | validate | test-alert
  grafana-password               Change the Grafana admin password
  down                           Stop the stack (data kept)
  uninstall                      Stop and DELETE all data

OPTIONS
  -y, --yes        Non-interactive, accept defaults (no alert channel)
  --dry-run        Only generate config files, start nothing
  --dir <path>     Install directory (default: \$HOME/monitoring-stack)
  -h, --help       Show this help
EOF
}

menu() {
  init_tty
  echo
  printf "%sWhat do you want to do?%s\n\n" "$BOLD" "$NC"
  echo "  1) Install monitoring SERVER   (Prometheus + Grafana + Alertmanager)"
  echo "  2) Install AGENT on this machine (so it can be monitored)"
  echo "  3) Add something to monitor    (server / app / website / port)"
  echo "  4) Show status"
  echo "  5) Quit"
  echo
  local c
  ask_text "Choice" "1" c
  case "$c" in
    1) install_server ;;
    2) install_agent ;;
    3)
      echo "  a) Server (agent)   b) Application (/metrics)   c) Website URL   d) TCP port"
      local t v n
      ask_text "Type" "a" t
      ask_text "Target (ip / host:port / URL)" "" v
      ask_text "Name (optional)" "" n
      case "${t,,}" in
        a) add_target node "$v" "$n" ;;
        b) add_target app  "$v" "$n" ;;
        c) add_target url  "$v" "$n" ;;
        d) add_target tcp  "$v" "$n" ;;
        *) die "Unknown type." ;;
      esac ;;
    4) cmd_status ;;
    *) info "Bye!" ;;
  esac
}

# --------------------------------- main --------------------------------------
main() {
  local cmd="" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes)  ASSUME_YES=true ;;
      --dry-run) DRY_RUN=true ;;
      --dir)     shift; MON_DIR="${1:?--dir needs a path}" ;;
      -h|--help) usage; exit 0 ;;
      *)         if [ -z "$cmd" ]; then cmd="$1"; else args+=("$1"); fi ;;
    esac
    shift
  done
  MON_DIR="${MON_DIR/#\~/$HOME}"

  case "$cmd" in
    "")               menu ;;
    server|install)   install_server ;;
    agent)            install_agent ;;
    remove-agent)     remove_agent ;;
    add-node)         add_target node "${args[0]:-}" "${args[1]:-}" ;;
    add-app)          add_target app  "${args[0]:-}" "${args[1]:-}" "${args[2]:-}" ;;
    add-url)          add_target url  "${args[0]:-}" "${args[1]:-}" ;;
    add-tcp)          add_target tcp  "${args[0]:-}" "${args[1]:-}" ;;
    remove)           remove_target "${args[0]:-}" ;;
    targets)          list_targets ;;
    status)           cmd_status ;;
    logs)             cmd_logs ${args[@]+"${args[@]}"} ;;
    restart)          cmd_restart ;;
    update)           cmd_update ;;
    validate)         cmd_validate ;;
    test-alert)       cmd_test_alert ;;
    grafana-password) cmd_grafana_password ;;
    down)             cmd_down ;;
    uninstall)        cmd_uninstall ;;
    help)             usage ;;
    *)                err "Unknown command: $cmd"; usage; exit 1 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
