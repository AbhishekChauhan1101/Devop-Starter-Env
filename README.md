# 🛠️ DevOps Environment Setup (Windows + WSL2 + Ubuntu)

Complete guide to set up a smooth DevOps workstation: **WSL2, Git, Docker, Docker Compose, Docker Hub, Python, Jenkins** and a few useful extras.

> Tested on: Windows 10 (22H2) / Windows 11 + Ubuntu 24.04 LTS (WSL2)
> Run all Linux commands **inside the Ubuntu (WSL) terminal** unless stated otherwise.

---

## 📑 Table of Contents

1. [Install WSL2 on Windows](#1-install-wsl2-on-windows)
2. [Enable systemd in WSL](#2-enable-systemd-in-wsl)
3. [Update system & base tools](#3-update-system--base-tools)
4. [Git](#4-git)
5. [Docker & Docker Compose](#5-docker--docker-compose)
6. [Docker Hub](#6-docker-hub)
7. [Python](#7-python)
8. [Jenkins](#8-jenkins)
9. [Optional DevOps tools](#9-optional-devops-tools)
10. [Verify everything](#10-verify-everything)
11. [Troubleshooting](#11-troubleshooting)
12. [Pro tips](#12-pro-tips)

---

## 1. Install WSL2 on Windows

Open **PowerShell as Administrator** (Win + X → Terminal (Admin)):

```powershell
# Install WSL with Ubuntu (default distro)
wsl --install

# Or choose a specific distro
wsl --list --online
wsl --install -d Ubuntu-24.04
```

Restart your PC when asked, then set up your Linux **username & password**.

Useful WSL commands (run in PowerShell):

```powershell
wsl --update                 # update WSL kernel
wsl --set-default-version 2  # make sure WSL2 is default
wsl -l -v                    # list distros + versions (VERSION should be 2)
wsl --shutdown               # fully stop WSL (needed after config changes)
```

> 💡 If a virtualization error comes: enable **Virtualization (VT-x / SVM)** in BIOS.

---

## 2. Enable systemd in WSL

Docker and Jenkins run as services, so systemd is required (usually already on in Ubuntu 24.04, but verify).

```bash
cat /etc/wsl.conf
```

If `systemd=true` is missing, add it:

```bash
sudo tee /etc/wsl.conf > /dev/null <<'EOF'
[boot]
systemd=true
EOF
```

Then in **PowerShell**:

```powershell
wsl --shutdown
```

Reopen Ubuntu and check:

```bash
systemctl is-system-running   # should say: running (or degraded)
```

---

## 3. Update system & base tools

```bash
sudo apt update && sudo apt upgrade -y

sudo apt install -y \
  curl wget unzip zip tar \
  ca-certificates gnupg lsb-release \
  software-properties-common apt-transport-https \
  build-essential make \
  jq tree htop net-tools vim nano
```

---

## 4. Git

```bash
sudo apt install -y git
git --version
```

Configure your identity:

```bash
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
git config --global init.defaultBranch main
git config --global pull.rebase false
git config --global core.editor "nano"
git config --list
```

### SSH key for GitHub / GitLab

```bash
ssh-keygen -t ed25519 -C "you@example.com"
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub     # copy this → GitHub → Settings → SSH keys
```

Test:

```bash
ssh -T git@github.com
```

---

## 5. Docker & Docker Compose

Docker Engine is installed **directly inside WSL** (no Docker Desktop needed). Choose **one** option.

| | Option A: Quick (`docker.io`) | Option B: Official Docker repo |
|---|---|---|
| Source | Ubuntu repository | Docker Inc. repository |
| Version | Slightly older | Always latest |
| Setup | 1 command | A few commands |
| Best for | Learning, practice, simple projects | Latest features, production-like setup |

> ⚠️ Don't mix both. If switching, remove the old one first (see 5.0).

### 5.0 Remove old / conflicting installs (optional but recommended)

```bash
sudo apt remove -y docker.io docker-compose docker-compose-v2 docker-doc \
  podman-docker containerd runc docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin docker-buildx
```

### Option A: Quick install (Ubuntu repo)

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-v2 docker-buildx
```

> ✅ Use `docker-compose-v2` (gives the modern `docker compose` command).
> ❌ Don't use `sudo apt install docker-compose` — that installs the old, deprecated v1.

### Option B: Official Docker repository (latest)

**Add Docker's repository:**

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
```

**Install Docker Engine + Compose + Buildx:**

```bash
sudo apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

### 5.1 Run Docker without `sudo` (important! — for both options)

```bash
sudo usermod -aG docker $USER
newgrp docker
```

> `newgrp docker` applies the group in the current terminal only. For a permanent effect, close and reopen the terminal (or run `wsl --shutdown` from PowerShell).

### 5.2 Start & enable Docker on boot

```bash
sudo systemctl enable --now docker
sudo systemctl enable --now containerd
sudo systemctl status docker --no-pager
```

### 5.3 Test

```bash
docker --version
docker compose version
docker run hello-world
```

### 5.4 Handy Docker commands

```bash
docker ps                      # running containers
docker ps -a                   # all containers
docker images                  # local images
docker logs -f <container>     # follow logs
docker exec -it <container> bash
docker stop $(docker ps -q)    # stop all running containers
docker system prune -a         # cleanup unused data (careful!)
```

Docker Compose basics:

```bash
docker compose up -d           # start in background
docker compose down            # stop & remove
docker compose ps
docker compose logs -f
docker compose up -d --build   # rebuild images
```

---

## 6. Docker Hub

Docker Hub is an **online image registry** — nothing to install. Once Docker is installed, `docker pull` fetches images from it automatically. Login is needed only for **pushing** or using **private** images.

1. Create a free account at [hub.docker.com](https://hub.docker.com)
2. Create an **Access Token**: Account Settings → Personal access tokens (use this instead of your password)

```bash
docker login -u <your-dockerhub-username>    # paste the access token as password
```

Pull, tag & push an image:

```bash
docker pull nginx
docker build -t myapp:latest .
docker tag myapp:latest <your-dockerhub-username>/myapp:latest
docker push <your-dockerhub-username>/myapp:latest
docker logout
```

> 💡 In Jenkins pipelines, store the Docker Hub username + token in **Manage Jenkins → Credentials**. Never hardcode them in a Jenkinsfile.

---

## 7. Python

Ubuntu 24.04 ships with Python 3.12.

```bash
sudo apt install -y python3 python3-pip python3-venv pipx
python3 --version
pip3 --version
pipx ensurepath
```

> ⚠️ On Ubuntu 24.04, plain `pip install <pkg>` is blocked (PEP 668: "externally-managed-environment").
> Use **virtual environments** for projects and **pipx** for CLI tools.

### Virtual environment (per project)

```bash
mkdir my-project && cd my-project
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install requests flask
deactivate                     # exit the venv
```

### CLI tools with pipx

```bash
pipx install pre-commit
```

Optional alias so `python` works:

```bash
sudo apt install -y python-is-python3
```

---

## 8. Jenkins

### 8.1 Install Java (required)

```bash
sudo apt install -y fontconfig openjdk-21-jre
java -version
```

### 8.2 Add Jenkins repository (LTS / stable)

```bash
sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key

echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] \
  https://pkg.jenkins.io/debian-stable binary/" | \
  sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null

sudo apt update
sudo apt install -y jenkins
```

### 8.3 Start & enable Jenkins

```bash
sudo systemctl enable --now jenkins
sudo systemctl status jenkins --no-pager
```

### 8.4 Let Jenkins use Docker (for pipelines that run `docker` commands)

```bash
sudo usermod -aG docker jenkins
sudo systemctl restart jenkins
```

Verify:

```bash
sudo -u jenkins docker ps
```

### 8.5 First-time setup

1. Open **http://localhost:8080** in your Windows browser
2. Get the admin password:

```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

3. Choose **Install suggested plugins** → create admin user → done ✅

### 8.6 Handy Jenkins commands

```bash
sudo systemctl start jenkins
sudo systemctl stop jenkins
sudo systemctl restart jenkins
sudo journalctl -u jenkins -f          # live logs
```

> 💡 Port 8080 busy? Run `sudo systemctl edit jenkins` and add:
> ```
> [Service]
> Environment="JENKINS_PORT=8090"
> ```
> then `sudo systemctl restart jenkins`.

---

## 9. Optional DevOps tools

### kubectl

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl
kubectl version --client
```

### Terraform

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt update && sudo apt install -y terraform
terraform -version
```

### Ansible

```bash
pipx install --include-deps ansible
ansible --version
```

### AWS CLI v2

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install
rm -rf aws awscliv2.zip
aws --version
```

### VS Code (recommended editor)

Install VS Code on Windows + the **WSL** extension, then from Ubuntu:

```bash
code .
```

---

## 10. Verify everything

Run this block to confirm the whole setup:

```bash
echo "=== OS ===";      lsb_release -d
echo "=== Git ===";     git --version
echo "=== Docker ===";  docker --version && docker compose version
echo "=== Python ===";  python3 --version && pip3 --version
echo "=== Java ===";    java -version 2>&1 | head -n 1
echo "=== Jenkins ==="; systemctl is-active jenkins
echo "=== Docker run ==="; docker run --rm hello-world | head -n 3
```

---

## 11. Troubleshooting

| Problem | Fix |
|---|---|
| `permission denied` on `/var/run/docker.sock` | `sudo usermod -aG docker $USER && newgrp docker` |
| `Cannot connect to the Docker daemon` | `sudo systemctl start docker` (check systemd is enabled, step 2) |
| `System has not been booted with systemd` | Add `systemd=true` in `/etc/wsl.conf`, then `wsl --shutdown` |
| `docker compose` not found | Option A: `sudo apt install docker-compose-v2` · Option B: `sudo apt install docker-compose-plugin` |
| Jenkins can't run `docker` in pipeline | `sudo usermod -aG docker jenkins && sudo systemctl restart jenkins` |
| `externally-managed-environment` error | Use `python3 -m venv` or `pipx` instead of global `pip` |
| Jenkins page not opening | `sudo systemctl status jenkins` and `sudo journalctl -u jenkins -n 50` |
| Slow file access in WSL | Keep projects inside `~/` (Linux filesystem), **not** in `/mnt/c/...` |
| `apt` GPG / key errors | Re-download the repo key (Docker step 5 / Jenkins step 8.2) and run `sudo apt update` |
| `docker push` denied | Run `docker login` and make sure the image is tagged `<username>/<repo>` |

---

## 12. Pro tips

- 📁 Keep all code in `~/projects`, not on `/mnt/c` → much faster Docker & Git.
- 🔄 Update regularly: `sudo apt update && sudo apt upgrade -y`
- 🧹 Clean Docker weekly: `docker system prune`
- 💾 Backup your WSL: `wsl --export Ubuntu-24.04 D:\backup\ubuntu.tar` (PowerShell)
- 🔐 Use Docker Hub **access tokens**, not your account password.
- 🧠 Add aliases in `~/.bashrc`:

```bash
alias dps='docker ps'
alias dcu='docker compose up -d'
alias dcd='docker compose down'
alias ll='ls -alh'
```

Then run `source ~/.bashrc`.

---

⭐ Happy DevOps-ing!
