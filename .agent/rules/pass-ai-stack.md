---
trigger: always_on
---

---
description: PaaS AI Stack - Never assume, always check official docs
alwaysApply: true
---

# PaaS AI Stack Documentation Rule

**NEVER ASSUME** - Always verify against official documentation before making changes or suggestions.

## Required Documentation Sources

Before making any configuration changes, API calls, or troubleshooting, consult:

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

## Mandatory Workflow

1. **Read** `paas-ai-stack/README.md` first for stack-specific configurations
2. **Check** official docs for any service-specific questions
3. **Verify** API endpoints, environment variables, and config options against docs
4. **Never** guess docker image tags, env vars, or API parameters

## Stack-Specific Files

- `.env` - All secrets and configuration
- `docker-compose.yml` - Service definitions
- `scripts/` - Bootstrap and maintenance scripts
- `skills/` - OpenClaw agent skills for each service