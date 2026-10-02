#!/usr/bin/env bash
# =============================================================================
#  setup-devops.sh  -  Interactive DevOps environment bootstrapper
#
#  Targets : Ubuntu / Debian  (native, VM, cloud VM, or WSL2)
#  Installs: Base tools, Git, Docker (+Compose), Python, Jenkins, kubectl,
#            Terraform, Ansible, AWS CLI, Docker Hub login
#
#  Usage   : chmod +x setup-devops.sh && ./setup-devops.sh
#            ./setup-devops.sh -y     # no questions: core set with defaults
#            ./setup-devops.sh -h     # help
#
#  Run as a NORMAL user (not root). The script calls sudo when needed.
# =============================================================================

set -uo pipefail

SCRIPT_VERSION="1.0.0"
LOG_FILE="$HOME/devops-setup-$(date +%Y%m%d-%H%M%S).log"
ASSUME_YES=false

# ----------------------------- colors & output -------------------------------
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; DIM=""; NC=""
fi

info()    { printf "%s[i]%s %s\n" "$BLUE" "$NC" "$*"; }
ok()      { printf "%s[✔]%s %s\n" "$GREEN" "$NC" "$*"; }
warn()    { printf "%s[!]%s %s\n" "$YELLOW" "$NC" "$*"; }
err()     { printf "%s[✘]%s %s\n" "$RED" "$NC" "$*" >&2; }
die()     { err "$*"; exit 1; }
section() { printf "\n%s━━━ %s ━━━%s\n" "$BOLD$CYAN" "$*" "$NC"; }

# ------------------------------- components ----------------------------------
KEYS=(base git docker python jenkins kubectl terraform ansible awscli dockerhub)
LABELS=(
  "Base tools      (curl, wget, unzip, jq, make, build-essential, vim...)"
  "Git             (+ identity config, optional SSH key)"
  "Docker          (Engine + Compose + Buildx, no-sudo setup)"
  "Python 3        (pip, venv, pipx)"
  "Jenkins         (+ Java, Docker access for pipelines)"
  "kubectl         (Kubernetes CLI)"
  "Terraform       (HashiCorp apt repo)"
  "Ansible         (via pipx)"
  "AWS CLI v2"
  "Docker Hub login (needs Docker)"
)
CORE=(base git docker python)

declare -A SELECTED
declare -A STATUS
for k in "${KEYS[@]}"; do SELECTED[$k]=false; STATUS[$k]="-"; done

# Options collected during the question phase (with defaults)
GIT_NAME=""; GIT_EMAIL=""; GIT_SSH=false
DOCKER_MODE="official"      # official | quick
REMOVE_OLD=false            # remove conflicting docker flavor first
KEEP_EXISTING=false         # keep conflicting flavor, skip docker pkg install
PY_ALIAS=false
JENKINS_CHANNEL="stable"    # stable | weekly
JENKINS_PORT="8080"
DH_USER=""

# ------------------------------- helpers -------------------------------------
is_wsl()      { grep -qi microsoft /proc/version 2>/dev/null; }
has_systemd() { [ -d /run/systemd/system ]; }
has_cmd()     { command -v "$1" >/dev/null 2>&1; }

apt_update()  { sudo apt-get update -y; }
apt_install() { sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }
pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }
pkg_available() { apt-cache show "$1" >/dev/null 2>&1; }

svc_enable_start() {
  local name="$1"
  if has_systemd; then
    sudo systemctl enable --now "$name"
  else
    sudo service "$name" start
  fi
}

os_codename() { . /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"; }

# Which Docker apt path to use: ubuntu or debian
docker_os_path() {
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) echo "$ID" ;;
    *) case "${ID_LIKE:-}" in
         *ubuntu*) echo "ubuntu" ;;
         *debian*) echo "debian" ;;
         *)        echo "ubuntu" ;;
       esac ;;
  esac
}

# ------------------------------- prompts -------------------------------------
ask_yn() {  # ask_yn "question" default(y|n)  -> exit 0 = yes
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
  if $ASSUME_YES; then printf -v "$__var" '%s' "$def"; return; fi
  read -r -u 3 -p "${CYAN}?${NC} ${prompt}${def:+ [$def]}: " ans || die "No input available."
  printf -v "$__var" '%s' "${ans:-$def}"
}

# ------------------------------- pre-flight ----------------------------------
usage() {
  cat <<EOF
setup-devops.sh v${SCRIPT_VERSION} - interactive DevOps environment setup

Usage:
  ./setup-devops.sh        Interactive mode (asks what to install)
  ./setup-devops.sh -y     Non-interactive: core tools (base, git, docker, python)
  ./setup-devops.sh -h     Show this help

Supported: Ubuntu / Debian (native, VM, WSL2). Run as a normal user.
Log file : ~/devops-setup-<timestamp>.log
EOF
}

preflight() {
  [ "$(id -u)" -ne 0 ] || die "Don't run as root. Use a normal user (the script uses sudo when needed)."
  has_cmd apt-get      || die "This script supports apt-based systems only (Ubuntu / Debian)."
  has_cmd sudo         || die "sudo is required. Install it first (as root: apt install sudo)."
  [ -r /etc/os-release ] || die "Cannot detect the OS (/etc/os-release missing)."
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *ubuntu*|*debian*) : ;;
    *) warn "Untested distro (${PRETTY_NAME:-unknown}). Continuing anyway..." ;;
  esac
}

banner() {
  clear 2>/dev/null || true
  printf "%s" "$BOLD$CYAN"
  cat <<'EOF'
  ____             ___                 _____            _
 |  _ \  _____   _/ _ \ _ __  ___     | ____|_ ____   _(_)_ __
 | | | |/ _ \ \ / / | | | '_ \/ __|    |  _| | '_ \ \ / / | '__|
 | |_| |  __/\ V /| |_| | |_) \__ \    | |___| | | \ V /| | |
 |____/ \___| \_/  \___/| .__/|___/    |_____|_| |_|\_/ |_|_|
                        |_|          Interactive Setup
EOF
  printf "%s\n" "$NC"
  . /etc/os-release
  info "System : ${PRETTY_NAME:-unknown} $(is_wsl && echo '(WSL)')"
  info "User   : $(id -un)"
  info "Log    : $LOG_FILE"
}

# --------------------------- question phase ----------------------------------
choose_components() {
  if $ASSUME_YES; then
    for k in "${CORE[@]}"; do SELECTED[$k]=true; done
    return
  fi

  echo
  printf "%sWhat do you want to install?%s\n\n" "$BOLD" "$NC"
  local i
  for i in "${!KEYS[@]}"; do
    printf "  %s%2d%s) %s\n" "$CYAN" $((i + 1)) "$NC" "${LABELS[$i]}"
  done
  echo
  printf "   %sa%s) Everything     %sc%s) Core (base + git + docker + python)     %sq%s) Quit\n\n" \
    "$CYAN" "$NC" "$CYAN" "$NC" "$CYAN" "$NC"

  local input tok n any=false
  while true; do
    ask_text "Enter numbers separated by space (e.g. 1 2 3 5), or a / c / q" "c" input
    any=false
    for k in "${KEYS[@]}"; do SELECTED[$k]=false; done
    local valid=true
    for tok in $input; do
      case "${tok,,}" in
        a|all)  for k in "${KEYS[@]}"; do SELECTED[$k]=true; done; any=true ;;
        c|core) for k in "${CORE[@]}"; do SELECTED[$k]=true; done; any=true ;;
        q|quit) info "Bye!"; exit 0 ;;
        *)
          if [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le "${#KEYS[@]}" ]; then
            n=$((tok - 1)); SELECTED[${KEYS[$n]}]=true; any=true
          else
            warn "Invalid choice: '$tok'"; valid=false
          fi ;;
      esac
    done
    if $valid && $any; then break; fi
  done
}

gather_options() {
  # Docker Hub needs Docker
  if [ "${SELECTED[dockerhub]}" = true ] && [ "${SELECTED[docker]}" = false ] && ! has_cmd docker; then
    warn "Docker Hub login needs Docker -> adding Docker to the list."
    SELECTED[docker]=true
  fi

  # ---- Git ----
  if [ "${SELECTED[git]}" = true ]; then
    section "Git options"
    local cur_name cur_email
    cur_name="$(git config --global user.name 2>/dev/null || true)"
    cur_email="$(git config --global user.email 2>/dev/null || true)"
    ask_text "Git user.name  (blank = skip)" "$cur_name" GIT_NAME
    ask_text "Git user.email (blank = skip)" "$cur_email" GIT_EMAIL
    if ask_yn "Generate an SSH key (ed25519) for GitHub/GitLab?" n; then GIT_SSH=true; fi
  fi

  # ---- Docker ----
  if [ "${SELECTED[docker]}" = true ]; then
    section "Docker options"
    echo "  1) Quick    - docker.io from the distro repo (older, simple)"
    echo "  2) Official - docker-ce from Docker's repo (latest, recommended)"
    local choice
    while true; do
      ask_text "Docker install method" "2" choice
      case "$choice" in
        1) DOCKER_MODE="quick";    break ;;
        2) DOCKER_MODE="official"; break ;;
        *) warn "Enter 1 or 2." ;;
      esac
    done

    local conflict=""
    if [ "$DOCKER_MODE" = "official" ] && pkg_installed docker.io; then conflict="docker.io"; fi
    if [ "$DOCKER_MODE" = "quick" ]    && pkg_installed docker-ce; then conflict="docker-ce"; fi
    if [ -n "$conflict" ]; then
      warn "'$conflict' is already installed and conflicts with the chosen method."
      if ask_yn "Remove it first? (your images & volumes are kept)" y; then
        REMOVE_OLD=true
      else
        KEEP_EXISTING=true
        warn "Keeping the existing Docker; package install will be skipped."
      fi
    fi
  fi

  # ---- Python ----
  if [ "${SELECTED[python]}" = true ]; then
    section "Python options"
    if ask_yn "Also install 'python-is-python3' (so 'python' works)?" n; then PY_ALIAS=true; fi
  fi

  # ---- Jenkins ----
  if [ "${SELECTED[jenkins]}" = true ]; then
    section "Jenkins options"
    echo "  1) LTS (stable, recommended)"
    echo "  2) Weekly (latest)"
    local ch
    while true; do
      ask_text "Jenkins release line" "1" ch
      case "$ch" in
        1) JENKINS_CHANNEL="stable"; break ;;
        2) JENKINS_CHANNEL="weekly"; break ;;
        *) warn "Enter 1 or 2." ;;
      esac
    done
    ask_text "Jenkins port" "8080" JENKINS_PORT
    if ! [[ "$JENKINS_PORT" =~ ^[0-9]+$ ]] || [ "$JENKINS_PORT" -lt 1024 ] || [ "$JENKINS_PORT" -gt 65535 ]; then
      warn "Invalid port, using 8080."; JENKINS_PORT="8080"
    fi
  fi

  # ---- Docker Hub ----
  if [ "${SELECTED[dockerhub]}" = true ]; then
    section "Docker Hub options"
    ask_text "Docker Hub username (blank = skip login)" "" DH_USER
  fi
}

# WSL needs systemd for Docker/Jenkins services
enable_wsl_systemd() {
  local f=/etc/wsl.conf
  if [ ! -f "$f" ]; then
    printf '[boot]\nsystemd=true\n' | sudo tee "$f" >/dev/null
  elif grep -q '^\[boot\]' "$f"; then
    if grep -qi '^systemd *=' "$f"; then
      sudo sed -i 's/^systemd *=.*/systemd=true/I' "$f"
    else
      sudo sed -i '/^\[boot\]/a systemd=true' "$f"
    fi
  else
    printf '\n[boot]\nsystemd=true\n' | sudo tee -a "$f" >/dev/null
  fi
}

wsl_systemd_check() {
  if is_wsl && ! has_systemd \
     && { [ "${SELECTED[docker]}" = true ] || [ "${SELECTED[jenkins]}" = true ]; }; then
    section "WSL: systemd is OFF"
    warn "Docker and Jenkins need systemd to run as services."
    if ask_yn "Enable systemd now? (needs a WSL restart, then re-run this script)" y; then
      enable_wsl_systemd
      ok "systemd enabled in /etc/wsl.conf"
      echo
      info "Now do this:"
      echo "   1) In Windows PowerShell run :  wsl --shutdown"
      echo "   2) Reopen Ubuntu and run again:  ./setup-devops.sh"
      exit 0
    else
      warn "Continuing without systemd (Jenkins may not start; Docker falls back to 'service')."
    fi
  fi
}

confirm_plan() {
  section "Summary - this will be installed"
  local i
  for i in "${!KEYS[@]}"; do
    if [ "${SELECTED[${KEYS[$i]}]}" = true ]; then
      printf "  %s•%s %s\n" "$GREEN" "$NC" "${LABELS[$i]}"
    fi
  done
  echo
  [ "${SELECTED[git]}" = true ]     && info "Git      : name='${GIT_NAME:-skip}' email='${GIT_EMAIL:-skip}' ssh-key=${GIT_SSH}"
  [ "${SELECTED[docker]}" = true ]  && info "Docker   : method=${DOCKER_MODE}"
  [ "${SELECTED[jenkins]}" = true ] && info "Jenkins  : ${JENKINS_CHANNEL} on port ${JENKINS_PORT}"
  [ "${SELECTED[dockerhub]}" = true ] && info "DockerHub: user='${DH_USER:-skip}'"
  echo
  if ! ask_yn "Proceed with installation?" y; then
    info "Cancelled. Nothing was changed."
    exit 0
  fi
}

# ------------------------------ installers -----------------------------------
# Each install_* runs in a subshell with 'set -e'.
# Return 0 = ok, 10 = skipped, anything else = failed.

install_prereqs() {
  apt_install ca-certificates curl wget gnupg lsb-release unzip
}

install_base() {
  apt_install \
    curl wget unzip zip tar \
    ca-certificates gnupg lsb-release \
    software-properties-common apt-transport-https \
    build-essential make \
    jq tree htop net-tools vim nano
}

install_git() {
  apt_install git
  if [ -n "$GIT_NAME" ];  then git config --global user.name "$GIT_NAME"; fi
  if [ -n "$GIT_EMAIL" ]; then git config --global user.email "$GIT_EMAIL"; fi
  git config --global init.defaultBranch main
  git config --global pull.rebase false

  if $GIT_SSH; then
    local key="$HOME/.ssh/id_ed25519"
    if [ -f "$key" ]; then
      info "SSH key already exists at $key (not overwriting)."
    else
      mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
      ssh-keygen -t ed25519 -C "${GIT_EMAIL:-$(id -un)@$(hostname)}" -f "$key" -N ""
      info "Key created WITHOUT passphrase. Add one later with: ssh-keygen -p -f $key"
    fi
    info "Add this public key to GitHub/GitLab (Settings -> SSH keys):"
    echo
    cat "$key.pub"
    echo
  fi
  return 0
}

install_docker() {
  local have_pkg=false
  if pkg_installed docker-ce || pkg_installed docker.io; then have_pkg=true; fi

  if ! $have_pkg && has_cmd docker; then
    warn "A 'docker' command exists but not from apt (Docker Desktop WSL integration?). Skipping."
    return 10
  fi

  # Remove the conflicting flavor if requested
  if $REMOVE_OLD; then
    local old_list rm_list=() p
    if [ "$DOCKER_MODE" = "official" ]; then
      old_list="docker.io docker-compose-v2 docker-buildx docker-compose"
    else
      old_list="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    fi
    for p in $old_list; do
      if pkg_installed "$p"; then rm_list+=("$p"); fi
    done
    if [ "${#rm_list[@]}" -gt 0 ]; then
      info "Removing: ${rm_list[*]}"
      sudo apt-get remove -y "${rm_list[@]}"
    fi
  fi

  if $KEEP_EXISTING; then
    info "Keeping existing Docker packages."
  elif [ "$DOCKER_MODE" = "quick" ]; then
    if pkg_installed docker.io; then
      info "docker.io already installed."
    else
      local pkgs=(docker.io) p
      for p in docker-compose-v2 docker-buildx; do
        if pkg_available "$p"; then pkgs+=("$p"); else warn "$p not available in your repos - skipped."; fi
      done
      apt_install "${pkgs[@]}"
    fi
  else
    if pkg_installed docker-ce; then
      info "docker-ce already installed."
    else
      local os_path codename
      os_path="$(docker_os_path)"
      codename="$(os_codename)"
      sudo install -m 0755 -d /etc/apt/keyrings
      sudo curl -fsSL "https://download.docker.com/linux/${os_path}/gpg" -o /etc/apt/keyrings/docker.asc
      sudo chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${os_path} ${codename} stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
      apt_update
      apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
  fi

  # Run docker without sudo
  sudo groupadd -f docker
  sudo usermod -aG docker "$(id -un)"

  # Start on boot
  svc_enable_start docker || warn "Could not start docker service automatically."
  svc_enable_start containerd 2>/dev/null || true

  # Smoke test (uses 'sg' because the new group isn't active in this shell yet)
  if sg docker -c "docker run --rm hello-world" >/dev/null 2>&1; then
    ok "Docker test container ran successfully."
  else
    warn "hello-world test didn't pass yet (daemon may be starting / no internet). Re-test after re-login."
  fi
  return 0
}

install_python() {
  apt_install python3 python3-pip python3-venv pipx
  pipx ensurepath || true
  if $PY_ALIAS; then apt_install python-is-python3; fi
  return 0
}

install_jenkins() {
  local java_pkg="openjdk-21-jre" repo
  if ! pkg_available "$java_pkg"; then
    warn "$java_pkg not in your repos; falling back to openjdk-17-jre."
    java_pkg="openjdk-17-jre"
  fi
  apt_install fontconfig "$java_pkg"

  if [ "$JENKINS_CHANNEL" = "stable" ]; then repo="debian-stable"; else repo="debian"; fi

  sudo mkdir -p /etc/apt/keyrings
  sudo wget -qO /etc/apt/keyrings/jenkins-keyring.asc "https://pkg.jenkins.io/${repo}/jenkins.io-2026.key"
  echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/${repo} binary/" \
    | sudo tee /etc/apt/sources.list.d/jenkins.list >/dev/null

  # Custom port (drop-in written BEFORE install so the first start uses it)
  if [ "$JENKINS_PORT" != "8080" ]; then
    sudo mkdir -p /etc/systemd/system/jenkins.service.d
    printf '[Service]\nEnvironment="JENKINS_PORT=%s"\n' "$JENKINS_PORT" \
      | sudo tee /etc/systemd/system/jenkins.service.d/override.conf >/dev/null
    if has_systemd; then sudo systemctl daemon-reload; fi
  fi

  apt_update
  apt_install jenkins

  # Let Jenkins pipelines use Docker
  if getent group docker >/dev/null 2>&1; then
    sudo usermod -aG docker jenkins
    info "Added 'jenkins' user to the docker group."
  fi

  svc_enable_start jenkins
  if has_systemd; then sudo systemctl restart jenkins; fi

  # Wait for the initial admin password to appear
  if has_systemd; then
    local f=/var/lib/jenkins/secrets/initialAdminPassword i
    info "Waiting for Jenkins to start (up to ~90s)..."
    for i in $(seq 1 30); do
      if sudo test -f "$f"; then break; fi
      sleep 3
    done
    if sudo test -f "$f"; then
      info "Jenkins initial admin password: $(sudo cat "$f")"
    else
      warn "Password file not ready yet. Later run: sudo cat $f"
    fi
  fi
  return 0
}

install_kubectl() {
  if has_cmd kubectl; then info "kubectl already installed - skipping."; return 0; fi
  local arch ver tmp
  arch="$(dpkg --print-architecture)"
  tmp="$(mktemp -d)"
  ver="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSL -o "$tmp/kubectl" "https://dl.k8s.io/release/${ver}/bin/linux/${arch}/kubectl"
  sudo install -o root -g root -m 0755 "$tmp/kubectl" /usr/local/bin/kubectl
  rm -rf "$tmp"
  return 0
}

install_terraform() {
  if has_cmd terraform; then info "terraform already installed - skipping."; return 0; fi
  curl -fsSL https://apt.releases.hashicorp.com/gpg \
    | sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(os_codename) main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
  apt_update
  apt_install terraform
}

install_ansible() {
  if has_cmd ansible || [ -x "$HOME/.local/bin/ansible" ]; then
    info "ansible already installed - skipping."; return 0
  fi
  apt_install pipx
  pipx install --include-deps ansible
  pipx ensurepath || true
  return 0
}

install_awscli() {
  if has_cmd aws; then info "aws CLI already installed - skipping."; return 0; fi
  local a tmp
  case "$(uname -m)" in
    x86_64)        a="x86_64" ;;
    aarch64|arm64) a="aarch64" ;;
    *) err "Unsupported architecture: $(uname -m)"; return 1 ;;
  esac
  tmp="$(mktemp -d)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${a}.zip" -o "$tmp/awscliv2.zip"
  unzip -q "$tmp/awscliv2.zip" -d "$tmp"
  sudo "$tmp/aws/install" --update
  rm -rf "$tmp"
  return 0
}

install_dockerhub() {
  if ! has_cmd docker; then err "Docker is not installed - cannot log in."; return 1; fi
  if [ -z "$DH_USER" ]; then info "No username given - skipping Docker Hub login."; return 10; fi
  info "Use an ACCESS TOKEN as the password (hub.docker.com -> Account Settings -> Personal access tokens)."
  sg docker -c "docker login -u $(printf '%q' "$DH_USER")"
}

# ------------------------------ run & report ---------------------------------
run_step() {
  local key="$1" rc
  section "Installing: $key"
  ( set -e; "install_${key}" )
  rc=$?
  case "$rc" in
    0)  STATUS[$key]="ok";      ok   "$key done." ;;
    10) STATUS[$key]="skipped"; warn "$key skipped." ;;
    *)  STATUS[$key]="failed";  err  "$key FAILED (see log: $LOG_FILE)" ;;
  esac
}

show_versions() {
  section "Installed versions"
  local k
  for k in "${KEYS[@]}"; do
    [ "${STATUS[$k]}" = "ok" ] || continue
    case "$k" in
      git)       printf "  git        : %s\n" "$(git --version 2>&1 | head -n1)" ;;
      docker)    printf "  docker     : %s | %s\n" "$(docker --version 2>&1 | head -n1)" "$(docker compose version 2>&1 | head -n1)" ;;
      python)    printf "  python     : %s | %s\n" "$(python3 --version 2>&1)" "$(pipx --version 2>&1 | head -n1)" ;;
      jenkins)   printf "  jenkins    : service is %s | %s\n" "$(systemctl is-active jenkins 2>/dev/null || echo 'n/a')" "$(java -version 2>&1 | head -n1)" ;;
      kubectl)   printf "  kubectl    : %s\n" "$(kubectl version --client 2>&1 | head -n1)" ;;
      terraform) printf "  terraform  : %s\n" "$(terraform -version 2>&1 | head -n1)" ;;
      ansible)   printf "  ansible    : %s\n" "$( ("$HOME/.local/bin/ansible" --version 2>&1 || ansible --version 2>&1) | head -n1)" ;;
      awscli)    printf "  aws        : %s\n" "$(aws --version 2>&1 | head -n1)" ;;
    esac
  done
}

final_summary() {
  show_versions

  section "Result"
  local k icon failed=0
  for k in "${KEYS[@]}"; do
    [ "${SELECTED[$k]}" = true ] || continue
    case "${STATUS[$k]}" in
      ok)      icon="${GREEN}✔ ok${NC}" ;;
      skipped) icon="${YELLOW}↷ skipped${NC}" ;;
      failed)  icon="${RED}✘ failed${NC}"; failed=1 ;;
      *)       icon="-" ;;
    esac
    printf "  %-12s %s\n" "$k" "$icon"
  done

  section "Next steps"
  if [ "${STATUS[docker]}" = "ok" ]; then
    echo "  • Docker without sudo : run  newgrp docker   (or close & reopen the terminal)"
  fi
  if [ "${STATUS[python]}" = "ok" ] || [ "${STATUS[ansible]}" = "ok" ]; then
    echo "  • pipx PATH           : run  source ~/.bashrc   (or reopen the terminal)"
  fi
  if [ "${STATUS[jenkins]}" = "ok" ]; then
    echo "  • Jenkins             : open http://localhost:${JENKINS_PORT}"
    echo "                          password: sudo cat /var/lib/jenkins/secrets/initialAdminPassword"
  fi
  if [ "${STATUS[git]}" = "ok" ] && $GIT_SSH; then
    echo "  • Git SSH key         : cat ~/.ssh/id_ed25519.pub  -> add to GitHub/GitLab"
  fi
  echo "  • Full log            : $LOG_FILE"
  echo
  if [ "$failed" -eq 1 ]; then
    err "Some steps failed. Check the log above and re-run the script for just those items."
    return 1
  fi
  ok "All done. Happy DevOps-ing! 🚀"
}

# --------------------------------- main --------------------------------------
main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    -y|--yes)  ASSUME_YES=true ;;
    "")        : ;;
    *)         usage; exit 1 ;;
  esac

  preflight

  # Read answers from the terminal even if stdin is piped
  if ! $ASSUME_YES; then
    if [ -r /dev/tty ] && : </dev/tty 2>/dev/null; then exec 3</dev/tty; else exec 3<&0; fi
  fi

  banner

  if sudo -n true 2>/dev/null; then
    ok "Passwordless sudo detected - no password needed."
  else
    info "Asking for sudo once (needed for installs)..."
    sudo -v || die "sudo authentication failed."
    ( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
  fi

  choose_components
  gather_options
  wsl_systemd_check
  confirm_plan

  # From here on, everything is also written to the log file
  exec > >(tee -a "$LOG_FILE") 2>&1

  section "Preparing system"
  apt_update
  apt_install ca-certificates curl wget gnupg lsb-release unzip

  local k
  for k in "${KEYS[@]}"; do
    if [ "${SELECTED[$k]}" = true ]; then run_step "$k"; fi
  done

  final_summary
  local rc=$?
  sleep 0.3   # let tee flush
  exit "$rc"
}

main "$@"
