# PaaS AI Stack

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/Docker-Required-2496ED?logo=docker&logoColor=white)](https://www.docker.com/)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey)]()

**Turnkey self-hosted platform** with Git, deployments, automation, AI chat, and AI gateway - all in a single Docker Compose stack.

## Table of Contents

- [Quick Start](#quick-start)
- [Services](#services)
- [Prerequisites](#prerequisites)
- [Architecture](#architecture)
- [Commands](#commands)
- [Configuration](#configuration)
- [Updating Services](#updating-services)
- [Security](#security)
- [Platform-Specific Notes](#platform-specific-notes)
- [Remote Host Setup](#remote-host-setup)
- [Troubleshooting](#troubleshooting)
- [Documentation & Resources](#documentation--resources)

---

## Quick Start

```bash
# 1. Clone and configure
git clone https://github.com/bullish0x/paas-ai-stack.git
cd paas-ai-stack
cp .env.template .env

# 2. Edit .env with your values:
#    - CLOUDFLARE_TUNNEL_TOKEN or CLOUDFLARE_API_TOKEN
#    - BASE_DOMAIN (your domain)
#    - ADMIN_EMAIL, ADMIN_USERNAME, ADMIN_PASSWORD
#    - At least ONE AI API key (ANTHROPIC_API_KEY, OPENROUTER_API_KEY, etc.)

# 3. Run bootstrap (one command does everything)
make bootstrap
```

**That's it.** The bootstrap handles all 23 steps automatically:
- Prerequisites verification & secret generation
- Admin account creation for Gitea, Coolify, n8n
- LobeChat SSO configuration (Casdoor OAuth app)
- API token generation for all services
- Coolify proxy configuration (native Traefik setup)
- Network connectivity & CI/CD integration
- Sample app deployment with verification
- Security hardening (disable registration, localhost-only ports)

**Cross-platform**: Works on Windows, macOS, and Linux.

<details>
<summary><strong>Alternative: Ansible Deployment</strong></summary>

For users who prefer Ansible's declarative infrastructure-as-code approach:

```bash
# Install Ansible collections
ansible-galaxy collection install -r ansible/requirements.yml

# Configure variables
cp ansible/inventory/group_vars/all.yml.example ansible/inventory/group_vars/all.yml
# Edit with your settings

# Run full bootstrap
ansible-playbook -i ansible/inventory/localhost.yml ansible/bootstrap.yml
```

See [ansible/README.md](ansible/README.md) for full documentation.

</details>

---

## Services

| Service | Implementation | Port | Domain |
|---------|----------------|------|--------|
| Git Server | Gitea | 3000 | gitea.* |
| CI Runner | Gitea Actions | — | — |
| Deploy Platform | Coolify | 8080 | coolify.* |
| Automation | n8n | 5678 | n8n.* |
| AI Chat | LobeChat | 3210 | lobe.* |
| Auth/SSO | Casdoor | 8000 | lobe-auth.* |
| Object Storage | MinIO | 9000/9001 | lobe-minio.* |
| AI Gateway | OpenClaw | 18789 | claw.* |
| Tunnel | Cloudflared | — | — |

**Local access** (for debugging):
- Gitea: http://127.0.0.1:3000
- Coolify: http://127.0.0.1:8080
- n8n: http://127.0.0.1:5678
- LobeChat: http://127.0.0.1:3210
- Casdoor: http://127.0.0.1:8000
- MinIO Console: http://127.0.0.1:9001
- OpenClaw: http://127.0.0.1:18789

---

## Prerequisites

### Required

1. **Docker Desktop** (or Docker Engine + Compose)
2. **Cloudflare account** with a domain
3. **Tools**: `curl`, `jq`, `openssl`

### Cloudflare Setup

You need either:
- **Option A (Recommended)**: API Token + Account/Zone IDs (bootstrap creates tunnel automatically)
- **Option B**: Pre-created Tunnel Token

<details>
<summary><strong>Creating the Cloudflare API Token</strong></summary>

1. Go to: https://dash.cloudflare.com/profile/api-tokens
2. Click **"Create Token"** → **"Create Custom Token"**
3. Configure these permissions:

| Permission | Access Level | Purpose |
|------------|--------------|---------|
| Account / Cloudflare Tunnel | Edit | Create and manage tunnels |
| Account / Cloudflare Tunnel | Read | List and verify tunnel status |
| Account / Workers AI | Edit | LobeChat RAG/library embeddings |
| Zone / DNS | Edit | Create DNS records for services |

4. **Account Resources**: Include → Select your account
5. **Zone Resources**: Include → Specific zone → Select your domain
6. Click **"Continue to summary"** → **"Create Token"**
7. Copy the token to `.env` as `CLOUDFLARE_API_TOKEN`

**Getting Account and Zone IDs:**
- **Account ID**: Zero Trust Dashboard URL: `https://one.dash.cloudflare.com/<ACCOUNT_ID>/`
- **Zone ID**: Domain Overview page → right sidebar under "API"

</details>

<details>
<summary><strong>Manual Tunnel Setup (Alternative)</strong></summary>

1. Go to: https://one.dash.cloudflare.com/ → Networks → Tunnels
2. Click **"Create a tunnel"**
3. Name it (e.g., "paas-stack")
4. Copy the tunnel token to `.env` as `CLOUDFLARE_TUNNEL_TOKEN`
5. Configure public hostnames for each service (see Architecture section)

</details>

<details>
<summary><strong>Installing Required Tools</strong></summary>

```bash
# Debian/Ubuntu
sudo apt update && sudo apt install -y curl jq openssl gettext-base

# macOS
brew install jq openssl gettext

# Windows (PowerShell)
winget install jqlang.jq
# curl and openssl are included with Git Bash
```

</details>

### SSH & Sudo (for Coolify deployments)

Coolify deploys to localhost via SSH. Enable SSH on your host:

<details>
<summary><strong>Linux</strong></summary>

```bash
# Ubuntu/Debian
sudo apt update && sudo apt install -y openssh-server
sudo systemctl enable --now ssh

# RHEL/Fedora/CentOS/Rocky
sudo dnf install -y openssh-server
sudo systemctl enable --now sshd
sudo firewall-cmd --permanent --add-service=ssh && sudo firewall-cmd --reload

# Arch
sudo pacman -S openssh
sudo systemctl enable --now sshd

# Passwordless sudo
echo "$(whoami) ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/coolify && sudo chmod 440 /etc/sudoers.d/coolify
```

</details>

<details>
<summary><strong>macOS</strong></summary>

1. System Settings → General → Sharing → Remote Login → ON
2. Set "Allow access for" to your user or "All users"

```bash
# Passwordless sudo
echo "$(whoami) ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/coolify && sudo chmod 440 /etc/sudoers.d/coolify
```

</details>

<details>
<summary><strong>Windows</strong></summary>

```powershell
# Install OpenSSH Server (PowerShell as Administrator)
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
```

Or via Settings: Apps → Optional Features → Add "OpenSSH Server"

**Important**: After bootstrap, run the Windows SSH setup script:
```powershell
.\scripts\setup-windows-ssh.ps1
```

See [Windows-Specific Notes](#windows) for details.

</details>

---

## Architecture

### Network Architecture

The stack uses two Docker networks that are bridged together:

| Network | Purpose | Created By |
|---------|---------|------------|
| `paas-network` | Core stack services | docker-compose |
| `coolify` | Deployed applications + Coolify internals | Coolify |

```
┌─────────────────────────────────────────────────────────────┐
│                      paas-network                           │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌───────┐ │
│  │ Gitea   │ │  n8n    │ │ OpenClaw│ │LobeChat │ │Coolify│ │
│  └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘ └───────┘ │
└───────┼───────────┼───────────┼───────────┼─────────────────┘
        │           │           │           │
        ▼           ▼           ▼           ▼
┌───────────────────────────────────────────────────────────┐
│                     coolify network                        │
│  ┌──────────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  │
│  │coolify-proxy │  │ app-1   │  │ app-2   │  │ app-N   │  │
│  │  (Traefik)   │  │(deployed)│ │(deployed)│ │(deployed)│ │
│  └──────────────┘  └─────────┘  └─────────┘  └─────────┘  │
└───────────────────────────────────────────────────────────┘
```

### Traffic Flow

```
Internet → Cloudflare (DDoS/WAF) → Tunnel → coolify-proxy (Traefik) → Container
```

**How deployed apps get routed:**
1. Cloudflare Tunnel has a wildcard route: `*.yourdomain.com → http://coolify-proxy:80`
2. Coolify's Traefik proxy reads Docker labels from deployed containers
3. Traefik routes requests based on the domain configured in Coolify

**Cross-network connections** (handled by bootstrap):

| Service | Networks | Why |
|---------|----------|-----|
| `gitea` | paas-network + coolify | Coolify helper clones repos via SSH |
| `n8n` | paas-network + coolify | Workflows can call deployed app APIs |
| `openclaw-cli` | paas-network + coolify | AI agent can interact with deployed apps |
| `lobe-chat` | paas-network + coolify | Chat can access deployed services |
| `coolify-proxy` | coolify + paas-network | Cloudflared routes to Traefik proxy |

### Tunnel Service Routes

| Service | Hostname | Service URL |
|---------|----------|-------------|
| Gitea | gitea.yourdomain.com | http://gitea:3000 |
| Coolify | coolify.yourdomain.com | http://coolify:8080 |
| Coolify Realtime | realtime.yourdomain.com | http://coolify-realtime:6001 |
| n8n | n8n.yourdomain.com | http://n8n:5678 |
| LobeChat | lobe.yourdomain.com | http://lobe-chat:3210 |
| Casdoor | lobe-auth.yourdomain.com | http://lobe-casdoor:8000 |
| OpenClaw | claw.yourdomain.com | http://openclaw-cli:18789 |
| Deployed Apps | *.yourdomain.com | http://coolify-proxy:80 |

---

## Commands

```bash
make bootstrap        # Full automated setup (recommended)
make start            # Start all services
make stop             # Stop all services  
make restart          # Restart all services
make restart-proxy    # Restart Coolify proxy (if routing issues)
make status           # Show status
make logs             # View all logs
make logs SERVICE=gitea  # View specific logs
make backup           # Backup data
make validate-coolify # Re-validate Coolify server (after SSH/sudo fix)

# Update commands
make update           # Update all services (with automatic backup)
make update-check     # Check for available updates
make update-openclaw  # Update OpenClaw only (rebuild from source)
make update-images    # Update docker images only
```

---

## Configuration

### AI API Keys

**Required**: At least ONE AI API key in `.env` for OpenClaw to function:

| Provider | Env Variable | Get Key |
|----------|--------------|---------|
| Anthropic (recommended) | `ANTHROPIC_API_KEY` | https://console.anthropic.com/settings/keys |
| OpenRouter (100+ models) | `OPENROUTER_API_KEY` | https://openrouter.ai/keys |
| OpenAI | `OPENAI_API_KEY` | https://platform.openai.com/api-keys |
| Google Gemini | `GEMINI_API_KEY` | https://aistudio.google.com/apikey |

OpenClaw auto-onboards on first start using the first available key (priority: Anthropic → OpenRouter → OpenAI → Gemini).

### Optional API Keys

| Feature | Env Var | Purpose | Get Key |
|---------|---------|---------|---------|
| Web Search | `BRAVE_API_KEY` | Agent can search the web | https://brave.com/search/api/ |
| Web Fetch | `FIRECRAWL_API_KEY` | Better web page extraction | https://firecrawl.dev/ |
| Text-to-Speech | `ELEVENLABS_API_KEY` | Voice responses | https://elevenlabs.io/ |

### Telegram Channel Setup

```bash
# 1. Create bot via @BotFather on Telegram
# 2. Add token to .env
TELEGRAM_BOT_TOKEN=your_token

# 3. Restart OpenClaw
docker compose restart openclaw-cli

# 4. DM your bot, then approve pairing code
docker exec openclaw-cli node dist/index.js pairing approve telegram <CODE>
```

### LobeChat AI Providers

LobeChat uses **direct provider access** (not routed through OpenClaw):
- **OpenRouter**: Primary - access Claude, GPT, Gemini via single key
- **Gemini**: Direct Google AI via `GEMINI_API_KEY`
- **DeepSeek**: Direct DeepSeek via `DEEPSEEK_API_KEY`
- **Cloudflare Workers AI**: Used for embeddings/RAG

### OpenClaw AI Gateway

- **Control UI**: https://claw.YOUR_DOMAIN (use `OPENCLAW_GATEWAY_TOKEN`)
- **HTTP API**: OpenAI-compatible `/v1/chat/completions` endpoint
- **WebSocket API**: For messaging channels
- **Webchat**: Built-in chat interface

**Skills available to OpenClaw** (at `/srv/paas/skills/`):

| Skill | Purpose |
|-------|---------|
| `gitea` | Manage Git repositories - create repos, branches, PRs, webhooks |
| `coolify` | Manage deployments - create apps, trigger deploys, manage envs |
| `n8n` | Workflow automation - create/execute workflows, manage credentials |
| `ci-cd` | Connect repos to Coolify, setup webhooks |
| `paas-ai-stack` | Overview skill - health checks, service status |
| `lobechat` | Interact with LobeChat knowledge base |

<details>
<summary><strong>Updating OpenClaw Configuration</strong></summary>

If you add/change API keys after initial setup:

**Option 1: Re-run configuration wizard**
```bash
docker exec -it openclaw-cli node dist/index.js configure
```

**Option 2: Re-run full onboarding**
```bash
docker exec openclaw-cli rm /root/.openclaw/.onboarded
docker compose restart openclaw-cli
```

**Option 3: Manual config changes**
```bash
docker exec openclaw-cli node dist/index.js config set <key> <value>
```

</details>

### CI/CD Integration (Gitea → Coolify)

**Automated setup** - creates complete CI/CD pipeline:

```bash
bash scripts/setup-ci-cd.sh <repo-name> <subdomain> [port]

# Example: Deploy "my-api" at https://api.yourdomain.com
bash scripts/setup-ci-cd.sh my-api api 8080
```

This automatically:
1. Creates/verifies repository in Gitea
2. Generates SSH deploy key pair
3. Adds keys to Coolify and Gitea
4. Creates application in Coolify
5. Configures webhook for auto-deploy

**Architecture:**
```
Push to Gitea → Webhook → Coolify → Clone via SSH → Build → Deploy → Traefik routes
```

<details>
<summary><strong>Post-Bootstrap: LobeChat + Casdoor (if login fails)</strong></summary>

If Casdoor login shows "Invalid client_id":
1. Open Casdoor: http://127.0.0.1:8000 (login: admin / 123)
2. Go to Identity → Applications → Add
3. Name: `lobechat`, Display name: `LobeChat`
4. Note the Client ID and Secret
5. Set Redirect URL: `https://<LOBE_DOMAIN>/api/auth/callback/casdoor`
6. Update `.env` with new credentials
7. Restart: `docker compose up -d lobe-chat --force-recreate`

</details>

<details>
<summary><strong>n8n Workflows</strong></summary>

n8n is ready for automation. Pre-configured credentials available:
- Gitea API: Use `GITEA_TOKEN` from .env
- Coolify API: Use `COOLIFY_TOKEN` from .env
- OpenClaw: Use `OPENCLAW_GATEWAY_TOKEN` from .env

</details>

---

## Updating Services

### Check for Updates

```bash
make update-check
```

### Update All Services

```bash
make update
```

This will:
1. Create a backup of the `data/` directory
2. Pull latest docker images
3. Rebuild OpenClaw from source
4. Restart all services

### Update OpenClaw Only

```bash
make update-openclaw

# Or specific version
bash scripts/update.sh --openclaw --version v2026.1.30
```

Pin version in `.env`: `OPENCLAW_VERSION=v2026.1.30`

### Rollback

```bash
bash scripts/update.sh --rollback backups/backup-20260131_120000.tar.gz
```

---

## Security

### Security Model

This stack is designed with **defense in depth**:

1. **Network Isolation**: All services localhost-only, accessed via Cloudflare Tunnel
2. **Container Isolation**: Services use `no-new-privileges`, rootless where possible
3. **Authentication**: All services require login, public registration disabled
4. **Secrets Management**: Auto-generated, stored in protected `.env` file

### Network Security

**Zero exposed ports** - all traffic flows through Cloudflare Tunnel:

```
Internet → Cloudflare (DDoS/WAF) → Tunnel → localhost:PORT → Container
```

- All ports bound to `127.0.0.1` only
- No firewall configuration needed
- Cloudflare provides DDoS protection, WAF, and SSL

### Container Security

| Service | Docker Socket | Privileged | Security Notes |
|---------|--------------|------------|----------------|
| Gitea | No | No | Standard container, `no-new-privileges` |
| Gitea Actions | No | Yes* | Rootless Docker-in-Docker (isolated) |
| Coolify | Read-only | Yes | Required for deployment management |
| n8n | No | No | Standard container, `no-new-privileges` |
| LobeChat | No | No | Standard container, `no-new-privileges` |
| OpenClaw | No | No | Standard container, `no-new-privileges` |

*Gitea Actions uses rootless DinD - jobs run in isolated Docker daemon, not host's.

### Authentication

After bootstrap:
- **Gitea**: Public registration DISABLED, requires sign-in
- **Coolify**: Requires admin login
- **n8n**: Requires admin login
- **LobeChat**: SSO via Casdoor
- **OpenClaw**: Gateway token required

### Secrets Management

```bash
chmod 600 .env  # Owner read/write only
```

Bootstrap auto-generates:
- Database passwords (48+ character hex)
- API tokens (64+ character hex)
- JWT secrets & encryption keys

### Security Checklist

- [ ] Strong admin password (12+ characters, mixed)
- [ ] `.env` file permissions set to 600
- [ ] Cloudflare Access policies configured (recommended)
- [ ] Regular backups enabled (`make backup`)
- [ ] Services updated regularly (`make update`)

<details>
<summary><strong>Additional Hardening</strong></summary>

**Cloudflare Access** - Add authentication layer:
1. Cloudflare Zero Trust → Access → Applications
2. Create application for each hostname
3. Add authentication policies (email OTP, SSO, IP allowlist)

**Firewall** (optional):
```bash
sudo ufw default deny incoming
sudo ufw allow from 103.21.244.0/22  # Cloudflare IP ranges
sudo ufw enable
```

</details>

---

## Platform-Specific Notes

### Linux

Linux is the target deployment platform. No special configuration needed beyond the prerequisites.

### macOS

<details>
<summary><strong>Click to expand macOS notes</strong></summary>

Running on macOS requires additional setup. The bootstrap handles most automatically:

| Issue | Cause | Bootstrap Fix |
|-------|-------|---------------|
| `/data` directory | macOS SIP blocks root writes | Creates synthetic firmlink via `/etc/synthetic.conf` |
| `chown: illegal group name` | macOS doesn't create user=group | Creates group matching username via `dscl` |
| `docker-credential-desktop` error | Docker Desktop credential helper | Removes `credsStore` from `~/.docker/config.json` |
| `docker` not in SSH PATH | `/usr/local/bin` not in non-interactive PATH | Adds to `~/.zshenv` and `~/.profile` |
| `no builder "desktop-linux"` | Docker Desktop builder context | Switches to `default` context |

**Reboot Required**: The `/data` synthetic firmlink requires a system reboot. Bootstrap will exit with instructions, then work normally on next run.

</details>

### Windows

<details>
<summary><strong>Click to expand Windows notes</strong></summary>

Running on Windows (via Git Bash with Docker Desktop) requires automatic adjustments:

| Issue | Cause | Bootstrap Fix |
|-------|-------|---------------|
| PostgreSQL permission errors | NTFS doesn't support Linux UID/GID | Uses named volumes via `docker-compose.windows.yml` |
| `/etc/timezone` not found | Windows lacks these files | Removes timezone volume mounts |
| Docker credential helper fails | Non-interactive SSH can't access credential store | Pre-pulls images before proxy start |
| SSH key permissions | Windows requires restrictive ACLs | `setup-windows-ssh.ps1` sets correct permissions |

**Coolify Proxy on Windows**: Bootstrap starts Traefik directly, bypassing Coolify's SSH-based setup which fails on Windows.

**Named Volumes**: PostgreSQL containers use named volumes instead of bind mounts on Windows. Data persists but isn't browsable in Explorer. Backup via `pg_dump`.

**SSH Setup (Required for Coolify deployments)**:

After bootstrap, run in Administrator PowerShell:
```powershell
.\scripts\setup-windows-ssh.ps1
```

This automatically:
- Installs OpenSSH Server (if needed)
- Copies Coolify's SSH key to correct location
- Sets proper file permissions
- Configures Git Bash as default SSH shell
- Tests the connection

<details>
<summary>Manual SSH setup (alternative)</summary>

```powershell
# Install OpenSSH Server
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

# Get Coolify's public key and add to authorized keys
Get-Content ".\data\coolify-ssh\id_ed25519.pub"
"<PUBLIC_KEY>" | Out-File -FilePath "C:\ProgramData\ssh\administrators_authorized_keys" -Encoding utf8 -Force
icacls "C:\ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"

# Set Git Bash as default shell
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Program Files\Git\bin\bash.exe" -PropertyType String -Force
Restart-Service sshd
```

</details>

**Validate in Coolify**: After SSH setup, go to Coolify → Servers → localhost → Validate Server.

</details>

---

## Remote Host Setup

For VPS, Raspberry Pi, or other remote hosts:

### 1. Connect and Install Docker

```bash
ssh user@your-server-ip

# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
exit  # Log out and back in
```

### 2. Clone and Configure

```bash
git clone https://github.com/bullish0x/paas-ai-stack.git
cd paas-ai-stack
cp .env.template .env
nano .env  # Set required values
```

### 3. Run Bootstrap

```bash
make bootstrap
```

<details>
<summary><strong>Raspberry Pi Notes</strong></summary>

- **Memory**: Minimum 4GB RAM (8GB preferred)
- **Storage**: Use SSD via USB 3.0 instead of SD card
- **Swap**: Enable for memory-intensive operations:
  ```bash
  sudo dphys-swapfile swapoff
  sudo nano /etc/dphys-swapfile  # Set CONF_SWAPSIZE=2048
  sudo dphys-swapfile setup
  sudo dphys-swapfile swapon
  ```
- **Docker**: ARM64 images used automatically

</details>

<details>
<summary><strong>VPS Notes</strong></summary>

- **Firewall**: No ports need to be opened - all traffic via Cloudflare Tunnel
- **Security**: Bootstrap disables public registration
- **Resources**: Minimum 2 vCPUs, 4GB RAM, 40GB storage

</details>

---

## Troubleshooting

**Coolify server not validated?**
```bash
# 1. Ensure SSH is enabled
# 2. Ensure passwordless sudo is configured
# 3. Re-validate
make validate-coolify
```

**Deployment fails with "Could not resolve hostname gitea"?**
```bash
docker network connect coolify gitea
docker network connect coolify n8n
docker network connect coolify openclaw-cli
docker network connect coolify lobe-chat
docker network connect paas-network coolify-proxy
```

**Deployed app not accessible?**
```bash
docker ps | grep coolify-proxy
make restart-proxy
```

**Webhook not triggering deployments?**
```bash
# Re-run CI/CD setup to regenerate matching secrets
bash scripts/setup-ci-cd.sh REPO_NAME SUBDOMAIN PORT
```

**Services not starting?**
```bash
make logs SERVICE=<service-name>
```

**Reset everything?**
```bash
make stop
rm -rf data/
make bootstrap
```

**Manual network fix** (if services can't communicate):
```bash
for svc in gitea n8n openclaw-cli lobe-chat; do
    docker network connect coolify $svc 2>/dev/null || true
done
docker network connect paas-network coolify-proxy 2>/dev/null || true
```

---

## Documentation & Resources

| Service | Official Docs | GitHub |
|---------|---------------|--------|
| Gitea | https://docs.gitea.com | https://github.com/go-gitea/gitea |
| Coolify | https://coolify.io/docs | https://github.com/coollabsio/coolify |
| n8n | https://docs.n8n.io | https://github.com/n8n-io/n8n |
| LobeChat | https://lobehub.com/docs | https://github.com/lobehub/lobe-chat |
| Casdoor | https://casdoor.org/docs | https://github.com/casdoor/casdoor |
| OpenClaw | https://openclaw.ai | https://github.com/anthropics/claude-code |
| MinIO | https://min.io/docs | https://github.com/minio/minio |
| Cloudflared | https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/ | https://github.com/cloudflare/cloudflared |
| Docker Compose | https://docs.docker.com/compose/ | — |

---

## Data

All persistent data stored in `./data/`

---

## License

MIT License - see [LICENSE](LICENSE) for details.
