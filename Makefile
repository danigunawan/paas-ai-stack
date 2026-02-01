.PHONY: help bootstrap setup init setup-ssh setup-accounts validate-coolify start stop restart restart-proxy logs status clean pull update update-check update-openclaw update-images

help: ## Show this help
	@echo ''
	@echo 'PaaS AI Stack - Self-Hosted Platform'
	@echo '====================================='
	@echo ''
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Quick Start:'
	@echo '  1. Copy .env.template to .env and set required values'
	@echo '  2. Run: make bootstrap'
	@echo ''
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ''

# Bootstrap - one command to set up everything
bootstrap: ## Full automated setup (generates secrets, starts services, creates accounts)
	@bash scripts/bootstrap.sh

# Individual setup steps (used by bootstrap)
setup: ## Create .env from template
	@if [ ! -f .env ]; then cp .env.template .env && echo "Created .env - edit it with your values"; else echo ".env exists"; fi

init: ## Create data directories
	@mkdir -p data/postgres-git data/postgres-n8n data/coolify-db data/coolify-redis
	@mkdir -p data/gitea data/gitea-actions data/coolify data/n8n
	@mkdir -p data/openclaw data/openclaw-workspace data/openclaw-ssh
	@echo "Data directories created"

setup-ssh: ## Generate SSH keys for OpenClaw host access (auto-adds to authorized_keys)
	@mkdir -p data/openclaw-ssh ~/.ssh
	@chmod 700 ~/.ssh
	@if [ -f data/openclaw-ssh/id_ed25519 ]; then \
		echo "SSH key already exists at data/openclaw-ssh/id_ed25519"; \
	else \
		ssh-keygen -t ed25519 -f data/openclaw-ssh/id_ed25519 -N "" -C "openclaw-gateway"; \
		echo "Host host" > data/openclaw-ssh/config; \
		echo "  HostName host.docker.internal" >> data/openclaw-ssh/config; \
		echo "  User $$(whoami)" >> data/openclaw-ssh/config; \
		echo "  IdentityFile /root/.ssh/id_ed25519" >> data/openclaw-ssh/config; \
		echo "  StrictHostKeyChecking no" >> data/openclaw-ssh/config; \
		chmod 600 data/openclaw-ssh/id_ed25519; \
		chmod 644 data/openclaw-ssh/config; \
		echo "SSH key generated"; \
	fi
	@if grep -q "openclaw-gateway" ~/.ssh/authorized_keys 2>/dev/null; then \
		echo "Key already in authorized_keys"; \
	else \
		cat data/openclaw-ssh/id_ed25519.pub >> ~/.ssh/authorized_keys; \
		chmod 600 ~/.ssh/authorized_keys; \
		echo "Key added to ~/.ssh/authorized_keys"; \
	fi
	@echo "OpenClaw SSH access configured"

setup-accounts: ## Create admin accounts for all services (requires ADMIN_* in .env)
	@bash scripts/setup-accounts.sh

validate-coolify: ## Validate Coolify server connection (run after enabling SSH + passwordless sudo)
	@echo "Validating Coolify server..."
	@docker exec coolify php artisan tinker --execute="use App\Models\Server; \$$s = Server::find(0); \$$s->settings->is_reachable = true; \$$s->settings->is_usable = true; \$$s->settings->save(); echo 'Server validated';" 2>/dev/null || echo "Validation failed"
	@echo "Check status at: http://127.0.0.1:8080/servers"

generate-secrets: ## Generate random secrets
	@echo "Secrets (copy to .env):"
	@echo ""
	@echo "POSTGRES_GIT_PASSWORD=$$(openssl rand -hex 24)"
	@echo "POSTGRES_N8N_PASSWORD=$$(openssl rand -hex 24)"
	@echo "POSTGRES_COOLIFY_PASSWORD=$$(openssl rand -hex 24)"
	@echo "COOLIFY_APP_KEY=$$(openssl rand -base64 32)"
	@echo "LOBE_POSTGRES_PASSWORD=$$(openssl rand -hex 24)"
	@echo "MINIO_ROOT_PASSWORD=$$(openssl rand -base64 24)"
	@echo "KEY_VAULTS_SECRET=$$(openssl rand -base64 32)"
	@echo "NEXT_AUTH_SECRET=$$(openssl rand -hex 32)"
	@echo "JWKS_KEY=$$(openssl rand -base64 32)"
	@echo "OPENCLAW_GATEWAY_TOKEN=$$(openssl rand -hex 32)"

# Operations
pull: ## Pull latest images
	docker compose pull

start: ## Start all services
	docker compose up -d

stop: ## Stop all services
	docker compose down

restart: ## Restart all services
	docker compose restart

restart-proxy: ## Restart Coolify proxy (native Coolify-managed)
	@echo "Restarting Coolify proxy via Coolify..."
	@# Use Coolify's native proxy management - don't modify proxy config
	@COOLIFY_TOKEN=$$(grep "^COOLIFY_TOKEN=" .env | cut -d'=' -f2-); \
	curl -sf -X POST "http://127.0.0.1:8080/api/v1/servers/0/proxy/stop" \
		-H "Authorization: Bearer $$COOLIFY_TOKEN" 2>/dev/null || true; \
	sleep 2; \
	curl -sf -X POST "http://127.0.0.1:8080/api/v1/servers/0/proxy/start" \
		-H "Authorization: Bearer $$COOLIFY_TOKEN" 2>/dev/null || \
		echo "Note: Start proxy manually from Coolify UI if API fails"
	@sleep 5
	@docker network connect paas-network coolify-proxy 2>/dev/null || true
	@docker network connect coolify gitea 2>/dev/null || true
	@echo "Proxy status:"
	@docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "coolify-proxy" || echo "Proxy not running - start from Coolify UI"

status: ## Show service status
	@docker compose ps

logs: ## View logs (usage: make logs SERVICE=gitea)
	@if [ -z "$(SERVICE)" ]; then docker compose logs -f; else docker compose logs -f $(SERVICE); fi

# Maintenance
clean: ## Remove unused Docker resources
	docker system prune -f

backup: ## Backup data directory
	@mkdir -p backups
	@tar -czf backups/backup-$$(date +%Y%m%d_%H%M%S).tar.gz data/
	@echo "Backup created in backups/"

build-openclaw: ## Rebuild OpenClaw image
	docker compose build openclaw-cli

# Updates
update: ## Update all services (pulls images, rebuilds OpenClaw, creates backup)
	@bash scripts/update.sh --all

update-check: ## Check for available updates
	@bash scripts/update.sh --check

update-openclaw: ## Update OpenClaw only (rebuild from source with backup)
	@bash scripts/update.sh --openclaw --backup

update-images: ## Update docker images only (pull latest)
	@bash scripts/update.sh --images
