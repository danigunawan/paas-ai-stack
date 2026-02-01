# PaaS AI Stack - Ansible Deployment

Ansible playbooks for deploying the PaaS AI Stack. Provides an alternative to the shell-based bootstrap for users who prefer Ansible's declarative infrastructure-as-code approach.

## Table of Contents

- [Why Ansible?](#why-ansible)
- [Quick Start](#quick-start)
- [Playbooks](#playbooks)
- [Services](#services)
- [Roles](#roles)
- [Tags](#tags)
- [Platform Support](#platform-support)
- [Variables Reference](#variables-reference)
- [Network Architecture](#network-architecture)
- [Troubleshooting](#troubleshooting)
- [OpenClaw Skills](#openclaw-skills)
- [CI/CD with Sample App](#cicd-with-sample-app)

---

## Why Ansible?

| Feature | Shell (`make bootstrap`) | Ansible |
|---------|--------------------------|---------|
| Idempotent | Partial | Full |
| Remote deployment | Manual SSH | Native |
| Variable validation | Basic | Comprehensive |
| Error handling | Exit on error | Retries with backoff |
| Parallel execution | None | Task-level |
| Dry-run | No | `--check` mode |
| Inventory management | None | Built-in |

---

## Quick Start

### Prerequisites

- Ansible 2.14+
- Python 3.9+
- Docker and Docker Compose on target hosts

<details>
<summary><strong>Install Ansible</strong></summary>

```bash
# macOS
brew install ansible

# Ubuntu/Debian
sudo apt update && sudo apt install -y ansible

# Windows (via pip in WSL or Git Bash)
pip install ansible

# pip (any platform)
pip install ansible
```

</details>

### 1. Install Required Collections

```bash
ansible-galaxy collection install -r requirements.yml
```

### 2. Configure Variables

```bash
cp inventory/group_vars/all.yml.example inventory/group_vars/all.yml
```

Edit `inventory/group_vars/all.yml` with your settings:

```yaml
# Required
base_domain: your-domain.com
admin_email: admin@your-domain.com
admin_username: admin
admin_password: your-strong-password

# Cloudflare (one of these options)
cloudflare_tunnel_token: your-tunnel-token
# OR API credentials for auto-creation:
cloudflare_api_token: your-api-token
cloudflare_account_id: your-account-id
cloudflare_zone_id: your-zone-id

# AI API Keys (at least one required)
anthropic_api_key: your-key
# OR
openrouter_api_key: your-key
```

### 3. Run Bootstrap

**Local deployment:**
```bash
ansible-playbook -i inventory/localhost.yml bootstrap.yml
```

**Remote deployment:**
```bash
cp inventory/production.yml.example inventory/production.yml
# Edit with your server details
ansible-playbook -i inventory/production.yml bootstrap.yml
```

---

## Playbooks

### `bootstrap.yml`

Full setup from scratch - equivalent to `make bootstrap`:

```bash
ansible-playbook -i inventory/localhost.yml bootstrap.yml
```

Runs all roles:
1. Prerequisites - Docker, tools, platform fixes
2. Secrets - Generate passwords, tokens
3. Cloudflare - Tunnel, DNS, routes
4. Deploy - Start stack, wait for health
5. Gitea, Coolify, n8n, LobeChat, OpenClaw - Service configuration
6. Integration - CI/CD, proxy, security hardening
7. Sample App - Optional CI/CD verification

### `site.yml`

Update/restart services after initial bootstrap:

```bash
ansible-playbook -i inventory/localhost.yml site.yml
ansible-playbook -i inventory/localhost.yml site.yml --tags=deploy
ansible-playbook -i inventory/localhost.yml site.yml --tags=services
```

### `update.yml`

Update all services (equivalent to `make update`):

```bash
ansible-playbook -i inventory/localhost.yml update.yml
ansible-playbook -i inventory/localhost.yml update.yml --tags=images
ansible-playbook -i inventory/localhost.yml update.yml --skip-tags=backup
ansible-playbook -i inventory/localhost.yml update.yml --tags=openclaw
```

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

---

## Roles

| Role | Purpose |
|------|---------|
| `prerequisites` | Verify Docker, tools, platform-specific fixes |
| `secrets` | Generate passwords, JWT keys, API tokens |
| `cloudflare` | Create tunnel, configure routes, DNS records |
| `deploy` | Start Docker Compose, wait for health checks |
| `gitea` | Admin user, API token generation |
| `coolify` | Admin user, SSH key, server configuration |
| `n8n` | Owner account setup, API key generation |
| `lobechat` | Casdoor OAuth app configuration |
| `openclaw` | Gateway verification, skills/scripts check |
| `integration` | Gitea Actions, Coolify proxy, network connectivity, security |
| `sample_app` | Optional hello-world for CI/CD verification |

---

## Tags

```bash
ansible-playbook -i inventory/localhost.yml bootstrap.yml --tags=prerequisites
ansible-playbook -i inventory/localhost.yml site.yml --tags=deploy
ansible-playbook -i inventory/localhost.yml site.yml --tags=gitea
ansible-playbook -i inventory/localhost.yml bootstrap.yml --skip-tags=cloudflare
```

Available tags:
- `prerequisites`, `secrets`, `cloudflare`, `deploy`
- `gitea`, `coolify`, `n8n`, `lobechat`, `openclaw`
- `services` (all service configuration)
- `integration`, `sample_app`
- `backup`, `images`, `openclaw`, `restart`, `verify` (update.yml)

---

## Platform Support

### Linux (Recommended)
- Ubuntu/Debian, RHEL/CentOS, Arch Linux
- Native Docker Engine
- All features fully supported

<details>
<summary><strong>macOS</strong></summary>

- Docker Desktop required
- Automatic fixes for `/data` directory (synthetic firmlink)
- User group creation for chown compatibility
- May require reboot for `/data` to take effect

</details>

<details>
<summary><strong>Windows</strong></summary>

- Docker Desktop with WSL2 backend
- Uses named volumes for PostgreSQL (NTFS compatibility)
- Requires `docker-compose.windows.yml` override
- SSH setup via `scripts/setup-windows-ssh.ps1` for Coolify deployments

</details>

---

## Variables Reference

### Required Variables

| Variable | Description |
|----------|-------------|
| `base_domain` | Your domain (e.g., `example.com`) |
| `admin_email` | Admin email address |
| `admin_password` | Admin password (min 12 chars) |
| `cloudflare_tunnel_token` | Cloudflare Tunnel token (or use API credentials) |

### AI API Keys (at least one required)

| Variable | Provider |
|----------|----------|
| `anthropic_api_key` | Anthropic (Claude) - recommended |
| `openrouter_api_key` | OpenRouter (100+ models) |
| `openai_api_key` | OpenAI (GPT) |
| `gemini_api_key` | Google Gemini |

<details>
<summary><strong>Cloudflare API (for auto-tunnel creation)</strong></summary>

| Variable | Description |
|----------|-------------|
| `cloudflare_api_token` | API token with Tunnel and DNS permissions |
| `cloudflare_account_id` | Cloudflare account ID |
| `cloudflare_zone_id` | DNS zone ID (for record creation) |

</details>

<details>
<summary><strong>Optional Variables</strong></summary>

| Variable | Default | Description |
|----------|---------|-------------|
| `timezone` | `America/New_York` | Server timezone |
| `admin_username` | `admin` | Admin username |
| `telegram_bot_token` | `` | Telegram bot token |
| `deploy_sample_app` | `false` | Deploy hello-world for CI/CD |
| `openclaw_version` | `main` | OpenClaw version |
| `firecrawl_api_key` | `` | Web content extraction |
| `elevenlabs_api_key` | `` | Text-to-speech |

</details>

---

## Network Architecture

Two Docker networks bridged together:

| Network | Purpose | Created By |
|---------|---------|------------|
| `paas-network` | Core stack services | docker-compose |
| `coolify` | Deployed applications | Coolify |

Cross-network connections (handled by integration role):

| Service | Networks | Why |
|---------|----------|-----|
| `gitea` | paas-network + coolify | Coolify clones repos via SSH |
| `n8n` | paas-network + coolify | Workflows call deployed APIs |
| `openclaw-cli` | paas-network + coolify | AI interacts with deployed apps |
| `lobe-chat` | paas-network + coolify | Chat accesses deployed services |
| `coolify-proxy` | coolify + paas-network | Routes tunnel traffic |

---

## Troubleshooting

<details>
<summary><strong>Check mode (dry-run)</strong></summary>

```bash
ansible-playbook -i inventory/localhost.yml bootstrap.yml --check
```

</details>

<details>
<summary><strong>Verbose output</strong></summary>

```bash
ansible-playbook -i inventory/localhost.yml bootstrap.yml -vvv
```

</details>

<details>
<summary><strong>Start from specific role</strong></summary>

```bash
ansible-playbook -i inventory/localhost.yml bootstrap.yml --start-at-task="Gitea setup"
```

</details>

<details>
<summary><strong>Common Issues</strong></summary>

**Coolify server not validated?**
```bash
ansible-playbook -i inventory/localhost.yml site.yml --tags=integration
# Or manually: https://coolify.yourdomain.com/servers
```

**Services can't communicate?**
```bash
docker network connect coolify gitea
docker network connect coolify n8n
docker network connect coolify openclaw-cli
docker network connect coolify lobe-chat
docker network connect paas-network coolify-proxy
```

**macOS: /data directory not found?**
```bash
# Reboot required after first run
sudo reboot
```

**Windows: PostgreSQL permission errors?**
```bash
# Ensure docker-compose.windows.yml exists
ls docker-compose.windows.yml
```

</details>

---

## OpenClaw Skills

OpenClaw has access to skills at `/srv/paas/skills/`:

| Skill | Purpose |
|-------|---------|
| `gitea` | Manage Git repositories |
| `coolify` | Manage deployments |
| `n8n` | Workflow automation |
| `ci-cd` | Connect repos to Coolify |
| `paas-ai-stack` | Health checks, service status |
| `lobechat` | LobeChat knowledge base |

Scripts at `/srv/paas/scripts/`:
- `setup-ci-cd.sh` - Automated CI/CD pipeline
- `refresh-tokens.sh` - Regenerate API tokens
- `update.sh` - Update services

---

## CI/CD with Sample App

Deploy a hello-world app to verify the full CI/CD pipeline:

```bash
ansible-playbook -i inventory/localhost.yml bootstrap.yml -e deploy_sample_app=true
```

This will:
1. Create `hello-world` repository in Gitea
2. Push sample app code
3. Run `setup-ci-cd.sh` to configure Coolify
4. Create webhook for auto-deploy

Access at: `https://hello.yourdomain.com`

---

## Files Generated

- `.env` - Environment variables
- `data/` - Service data directories
- `data/coolify-ssh/` - SSH keys for Coolify
- `~/.ssh/authorized_keys` - Coolify SSH key added

---

## Integration with Shell Bootstrap

If you already ran `make bootstrap`:

```bash
# Update existing installation (preserves secrets)
ansible-playbook -i inventory/localhost.yml site.yml
```

Your existing `.env` will be backed up before any changes.
