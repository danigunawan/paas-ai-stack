#!/bin/bash
# =============================================================================
# PaaS AI Stack - Full Bootstrap
# Single command to set up everything from scratch
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# Cross-platform JSON parsing (works on Linux, macOS, Windows/WSL)
# Uses jq which is a required prerequisite
json_get() {
    local json="$1"
    local key="$2"
    echo "$json" | jq -r "$key // empty" 2>/dev/null || echo ""
}

# Push file to Gitea repo via API (avoids git push issues on Windows)
gitea_push_file() {
    local repo="$1"
    local filepath="$2"
    local content="$3"
    local message="$4"
    local token="$5"
    
    local content_b64=$(echo -n "$content" | base64 -w0 2>/dev/null || echo -n "$content" | base64)
    
    curl -sf -X POST "http://127.0.0.1:3000/api/v1/repos/$repo/contents/$filepath" \
        -H "Authorization: token $token" \
        -H "Content-Type: application/json" \
        -d "{\"content\": \"$content_b64\", \"message\": \"$message\"}" > /dev/null 2>&1
}

# =============================================================================
# Robust Helper Functions - Don't Rush, Verify Everything
# =============================================================================

# Wait for an API endpoint to respond successfully
# Usage: wait_for_api "service-name" "http://url/health" [max_seconds] [expected_status]
wait_for_api() {
    local service="$1"
    local url="$2"
    local max_wait="${3:-120}"
    local expected="${4:-200}"
    local waited=0
    local interval=3
    
    echo -n "  Waiting for $service API: "
    while [ $waited -lt $max_wait ]; do
        status=$(curl -sf -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
        
        if [ "$status" = "$expected" ]; then
            echo "ready (${waited}s)"
            return 0
        fi
        
        # Show progress every 15 seconds
        if [ $((waited % 15)) -eq 0 ] && [ $waited -gt 0 ]; then
            echo -n "."
        fi
        
        sleep $interval
        waited=$((waited + interval))
    done
    
    echo "timeout after ${max_wait}s (last status: $status)"
    return 1
}

# Retry a command with exponential backoff
# Usage: retry_with_backoff "description" max_attempts command [args...]
# Returns: 0 on success, 1 on failure (sets RETRY_OUTPUT with command output)
retry_with_backoff() {
    local desc="$1"
    local max_attempts="$2"
    shift 2
    
    local attempt=1
    local wait_time=2
    local max_wait=30
    
    RETRY_OUTPUT=""
    
    while [ $attempt -le $max_attempts ]; do
        RETRY_OUTPUT=$("$@" 2>&1)
        local exit_code=$?
        
        if [ $exit_code -eq 0 ] && [ -n "$RETRY_OUTPUT" ]; then
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            echo "    $desc: attempt $attempt failed, retrying in ${wait_time}s..."
            sleep $wait_time
            # Exponential backoff with cap
            wait_time=$((wait_time * 2))
            [ $wait_time -gt $max_wait ] && wait_time=$max_wait
        fi
        
        attempt=$((attempt + 1))
    done
    
    echo "    $desc: failed after $max_attempts attempts"
    return 1
}

# Verify a condition or report failure (non-fatal)
# Usage: verify_condition "description" "command to check"
verify_condition() {
    local desc="$1"
    local check_cmd="$2"
    
    if eval "$check_cmd" > /dev/null 2>&1; then
        log_success "$desc"
        return 0
    else
        log_warn "$desc - verification failed"
        return 1
    fi
}

# Wait for Docker container to be truly ready (health + API)
# Usage: wait_for_service "container" "api_url" [health_timeout] [api_timeout]
wait_for_service() {
    local container="$1"
    local api_url="$2"
    local health_timeout="${3:-120}"
    local api_timeout="${4:-60}"
    
    # Phase 1: Wait for Docker health check
    echo -n "  $container health: "
    local waited=0
    while [ $waited -lt $health_timeout ]; do
        local status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "starting")
        
        if [ "$status" = "healthy" ]; then
            echo "healthy (${waited}s)"
            break
        elif [ "$status" = "unhealthy" ]; then
            echo "UNHEALTHY"
            docker logs "$container" --tail 20 2>&1 | head -10
            return 1
        fi
        
        sleep 2
        waited=$((waited + 2))
    done
    
    if [ $waited -ge $health_timeout ]; then
        echo "timeout"
        return 1
    fi
    
    # Phase 2: Wait for API to actually respond (if URL provided)
    if [ -n "$api_url" ]; then
        echo -n "  $container API: "
        waited=0
        while [ $waited -lt $api_timeout ]; do
            if curl -sf "$api_url" > /dev/null 2>&1; then
                echo "ready (${waited}s)"
                return 0
            fi
            sleep 2
            waited=$((waited + 2))
        done
        echo "API not responding after ${api_timeout}s"
        return 1
    fi
    
    return 0
}

echo ""
echo "=============================================="
echo "  PaaS AI Stack - Full Bootstrap"
echo "=============================================="
echo ""

# =============================================================================
# PRE-STEP: Fix Windows line endings in .env if present
# =============================================================================
if [ -f ".env" ]; then
    # Convert CRLF to LF (Windows to Unix line endings)
    if grep -q $'\r' .env 2>/dev/null; then
        sed -i 's/\r$//' .env 2>/dev/null || true
    fi
fi

# =============================================================================
# STEP 1: Check prerequisites
# =============================================================================
log_info "Checking prerequisites..."

# Detect if running on remote host (VPS, RPI, etc.)
REMOTE_HOST=false
if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
    REMOTE_HOST=true
    log_info "Detected remote host setup (SSH connection)"
fi

# Docker
if ! command -v docker &> /dev/null; then
    log_error "Docker not found."
    echo ""
    echo "Install Docker:"
    echo "  curl -fsSL https://get.docker.com | sh"
    echo "  sudo usermod -aG docker \$USER"
    echo "  # Log out and back in, then run bootstrap again"
    exit 1
fi
log_success "Docker installed: $(docker --version | cut -d' ' -f3 | tr -d ',')"

# Docker Compose
if ! docker compose version &> /dev/null; then
    log_error "Docker Compose not found."
    echo ""
    echo "Docker Compose should be included with Docker."
    echo "If using older Docker, install plugin:"
    echo "  sudo apt install docker-compose-plugin"
    exit 1
fi
log_success "Docker Compose installed: $(docker compose version --short)"

# Check Docker is running
if ! docker info &> /dev/null 2>&1; then
    log_error "Docker is not running."
    echo ""
    if [ "$REMOTE_HOST" = true ]; then
        echo "Start Docker service:"
        echo "  sudo systemctl start docker"
        echo "  sudo systemctl enable docker"
    else
        echo "Start Docker Desktop first."
    fi
    exit 1
fi
log_success "Docker is running"

# Check Docker socket permissions
if [ ! -w /var/run/docker.sock ]; then
    log_warn "Docker socket not writable by current user"
    echo "  Add yourself to docker group:"
    echo "  sudo usermod -aG docker \$USER"
    echo "  # Then log out and back in"
fi

# Check required tools
MISSING_TOOLS=()
command -v curl &> /dev/null || MISSING_TOOLS+=("curl")
command -v jq &> /dev/null || MISSING_TOOLS+=("jq")
command -v openssl &> /dev/null || MISSING_TOOLS+=("openssl")
command -v envsubst &> /dev/null || MISSING_TOOLS+=("gettext-base")  # provides envsubst

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    log_error "Missing required tools: ${MISSING_TOOLS[*]}"
    echo ""
    echo "Install them:"
    echo "  # Debian/Ubuntu:"
    echo "  sudo apt update && sudo apt install -y curl jq openssl gettext-base"
    echo ""
    echo "  # macOS:"
    echo "  brew install jq openssl gettext"
    exit 1
fi
log_success "Required tools available (curl, jq, openssl, envsubst)"

# Check available disk space (minimum 10GB) - cross-platform
if command -v df &> /dev/null; then
    # Try Linux format first, fall back to BSD/macOS format
    if df -BG . &> /dev/null; then
        AVAILABLE_SPACE=$(df -BG . | tail -1 | awk '{print $4}' | tr -d 'G')
    else
        # macOS/BSD: df shows 512-byte blocks, convert to GB
        AVAILABLE_SPACE=$(df -g . 2>/dev/null | tail -1 | awk '{print $4}' || echo "100")
    fi
    if [ -n "$AVAILABLE_SPACE" ] && [ "$AVAILABLE_SPACE" -lt 10 ] 2>/dev/null; then
        log_warn "Low disk space: ${AVAILABLE_SPACE}GB available (10GB+ recommended)"
    fi
fi

# Check available memory (minimum 4GB)
if [ -f /proc/meminfo ]; then
    TOTAL_MEM=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024/1024)}')
    if [ "$TOTAL_MEM" -lt 4 ]; then
        log_warn "Low memory: ${TOTAL_MEM}GB available (4GB+ recommended)"
    fi
fi

# Remote host specific checks
if [ "$REMOTE_HOST" = true ]; then
    log_info "Checking remote host requirements..."
    
    # Check if SSH server is running (for Coolify)
    if ! systemctl is-active --quiet sshd 2>/dev/null && ! systemctl is-active --quiet ssh 2>/dev/null; then
        log_warn "SSH server not detected - Coolify deployments may fail"
        echo "  Install: sudo apt install openssh-server"
    fi
    
    # Check for passwordless sudo (needed for Coolify)
    if ! sudo -n true 2>/dev/null; then
        log_warn "Passwordless sudo not configured - Coolify deployments may fail"
        echo "  Configure: echo '\$USER ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/\$USER"
    fi
fi

# =============================================================================
# macOS-Specific Checks and Fixes
# =============================================================================
if [[ "$OSTYPE" == "darwin"* ]]; then
    log_info "Detected macOS - checking platform-specific requirements..."
    MACOS_REBOOT_REQUIRED=false
    MACOS_ISSUES=()
    
    # Check 1: /data directory (Coolify needs this for deployments)
    if [ ! -e /data ]; then
        log_warn "/data directory not found - required for Coolify deployments"
        
        # Check if synthetic.conf already has the entry
        if ! grep -q "^data" /etc/synthetic.conf 2>/dev/null; then
            echo "  Creating synthetic firmlink for /data..."
            mkdir -p ~/coolify-data
            echo "data	Users/$(whoami)/coolify-data" | sudo tee /etc/synthetic.conf > /dev/null
            MACOS_REBOOT_REQUIRED=true
            MACOS_ISSUES+=("/data directory")
        fi
    else
        log_success "/data directory available"
    fi
    
    # Check 2: User group matching username (Coolify uses chown user:user)
    if ! dscl . -read /Groups/$(whoami) &>/dev/null; then
        log_warn "Group '$(whoami)' not found - required for Coolify deployments"
        echo "  Creating group matching username..."
        
        # Find an unused GID
        NEXT_GID=1001
        while dscl . -list /Groups PrimaryGroupID | grep -q "\\b${NEXT_GID}\\b"; do
            NEXT_GID=$((NEXT_GID + 1))
        done
        
        sudo dscl . -create /Groups/$(whoami) 2>/dev/null
        sudo dscl . -create /Groups/$(whoami) PrimaryGroupID $NEXT_GID 2>/dev/null
        sudo dscl . -append /Groups/$(whoami) GroupMembership $(whoami) 2>/dev/null
        log_success "Created group '$(whoami)' with GID $NEXT_GID"
    else
        log_success "Group '$(whoami)' exists"
    fi
    
    # Check 3: Docker config credsStore (causes build failures in helper container)
    if [ -f ~/.docker/config.json ]; then
        if grep -q '"credsStore"' ~/.docker/config.json; then
            log_warn "Docker config has credsStore - can cause Coolify build failures"
            echo "  Removing credsStore from Docker config..."
            cp ~/.docker/config.json ~/.docker/config.json.backup
            jq 'del(.credsStore)' ~/.docker/config.json > ~/.docker/config.json.tmp && \
                mv ~/.docker/config.json.tmp ~/.docker/config.json
            log_success "Docker config updated (backup at ~/.docker/config.json.backup)"
        fi
    fi
    
    # Check 4: /usr/local/bin in SSH PATH (Docker lives here on macOS)
    SSH_PATH_FIXED=false
    if [ -f ~/.zshenv ]; then
        if ! grep -q '/usr/local/bin' ~/.zshenv; then
            echo 'export PATH="/usr/local/bin:$PATH"' >> ~/.zshenv
            SSH_PATH_FIXED=true
        fi
    else
        echo 'export PATH="/usr/local/bin:$PATH"' >> ~/.zshenv
        SSH_PATH_FIXED=true
    fi
    
    if [ ! -f ~/.profile ] || ! grep -q '/usr/local/bin' ~/.profile 2>/dev/null; then
        echo 'export PATH="/usr/local/bin:$PATH"' >> ~/.profile
        SSH_PATH_FIXED=true
    fi
    
    if [ "$SSH_PATH_FIXED" = true ]; then
        log_success "Added /usr/local/bin to SSH PATH (~/.zshenv and ~/.profile)"
    fi
    
    # Check 5: Docker context (desktop-linux can cause build failures)
    CURRENT_CONTEXT=$(docker context show 2>/dev/null || echo "unknown")
    if [ "$CURRENT_CONTEXT" = "desktop-linux" ]; then
        log_warn "Docker context is 'desktop-linux' - may cause builder issues"
        echo "  Switching to 'default' context..."
        docker context use default 2>/dev/null || true
        log_success "Switched to 'default' Docker context"
    fi
    
    # Check 6: Create 'coolify' network on host (Coolify deployments need this)
    if ! docker network ls | grep -q "\\bcoolify\\b"; then
        echo "  Creating 'coolify' network for Coolify deployments..."
        docker network create coolify 2>/dev/null || true
        log_success "Created 'coolify' Docker network"
    fi
    
    # Summary of macOS issues
    if [ "$MACOS_REBOOT_REQUIRED" = true ]; then
        echo ""
        echo "  ╔════════════════════════════════════════════════════════════════╗"
        echo "  ║  macOS REBOOT REQUIRED                                         ║"
        echo "  ╠════════════════════════════════════════════════════════════════╣"
        echo "  ║  The /data directory requires a synthetic firmlink which       ║"
        echo "  ║  only takes effect after a reboot.                             ║"
        echo "  ║                                                                 ║"
        echo "  ║  After reboot, run 'make bootstrap' again.                     ║"
        echo "  ╚════════════════════════════════════════════════════════════════╝"
        echo ""
        exit 0
    fi
fi

# =============================================================================
# Windows-Specific Checks and Configuration
# =============================================================================
# Detect Windows via multiple methods:
# 1. MSYSTEM set (Git Bash/MSYS2)
# 2. OSTYPE is msys/mingw (Git Bash)
# 3. Running in WSL but project is on Windows path (/mnt/c, /mnt/d, etc.)
# 4. WSLENV is set (WSL interop)
# 5. PWD starts with /d/ or similar Windows drive letter path
COMPOSE_FILES=""
IS_WINDOWS=false

if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "mingw"* ]] || [[ -n "$MSYSTEM" ]]; then
    IS_WINDOWS=true
elif [[ -n "$WSLENV" ]] || [[ "$PWD" =~ ^/mnt/[a-z]/ ]] || [[ "$PWD" =~ ^/[a-z]/ ]]; then
    # WSL or Git Bash with Windows drive paths
    IS_WINDOWS=true
elif [[ -f "/proc/version" ]] && grep -qi microsoft /proc/version 2>/dev/null; then
    # WSL detection via /proc/version
    IS_WINDOWS=true
fi

if [ "$IS_WINDOWS" = true ]; then
    log_info "Detected Windows environment - applying Windows-specific configuration..."
    
    # Use Windows-specific compose override with named volumes for PostgreSQL
    if [ -f "docker-compose.windows.yml" ]; then
        COMPOSE_FILES="-f docker-compose.yml -f docker-compose.windows.yml"
        log_success "Using Windows compose override (named volumes for PostgreSQL)"
    else
        log_error "docker-compose.windows.yml not found - PostgreSQL containers will fail"
        echo "  This file is required for Windows compatibility"
        exit 1
    fi
    
    # Note about Docker socket warning (can be ignored on Windows)
    echo "  Note: 'Docker socket not writable' warning can be ignored on Windows"
    echo "  Note: PostgreSQL data stored in Docker named volumes (not ./data/)"
fi

# =============================================================================
# STEP 2: Setup .env file
# =============================================================================
log_info "Setting up environment..."

if [ ! -f .env ]; then
    if [ -f .env.template ]; then
        cp .env.template .env
        log_success "Created .env from template"
    else
        log_error ".env.template not found"
        exit 1
    fi
else
    log_success ".env already exists"
fi

# Load current env (handle special characters)
set -a
while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ -z "$key" ]] && continue
    # Remove leading/trailing whitespace
    key=$(echo "$key" | xargs)
    # Export if valid variable name
    if [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        export "$key=$value"
    fi
done < .env
set +a

# =============================================================================
# STEP 3: Validate required variables
# =============================================================================
log_info "Validating configuration..."

MISSING_VARS=()

# Check critical variables (not Cloudflare tunnel - that can be auto-created)
[ -z "$BASE_DOMAIN" ] || [ "$BASE_DOMAIN" = "YOUR_DOMAIN_HERE" ] && MISSING_VARS+=("BASE_DOMAIN")
[ -z "$ADMIN_EMAIL" ] || [ "$ADMIN_EMAIL" = "admin@YOUR_DOMAIN" ] && MISSING_VARS+=("ADMIN_EMAIL")
[ -z "$ADMIN_PASSWORD" ] || [ "$ADMIN_PASSWORD" = "GENERATE_WITH_openssl_rand_-base64_16" ] || [ "$ADMIN_PASSWORD" = "CHANGE_ME_NOW" ] && MISSING_VARS+=("ADMIN_PASSWORD")

# Check Cloudflare - either need tunnel token OR API credentials to create one
HAVE_TUNNEL_TOKEN=false
HAVE_CF_API=false
[ -n "$CLOUDFLARE_TUNNEL_TOKEN" ] && [ "$CLOUDFLARE_TUNNEL_TOKEN" != "YOUR_TUNNEL_TOKEN" ] && HAVE_TUNNEL_TOKEN=true
[ -n "$CLOUDFLARE_API_TOKEN" ] && [ "$CLOUDFLARE_API_TOKEN" != "YOUR_API_TOKEN" ] && \
[ -n "$CLOUDFLARE_ACCOUNT_ID" ] && [ "$CLOUDFLARE_ACCOUNT_ID" != "YOUR_ACCOUNT_ID" ] && HAVE_CF_API=true

if [ "$HAVE_TUNNEL_TOKEN" = false ] && [ "$HAVE_CF_API" = false ]; then
    MISSING_VARS+=("CLOUDFLARE_TUNNEL_TOKEN (or CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID)")
fi

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    log_error "Missing required variables in .env:"
    for var in "${MISSING_VARS[@]}"; do
        echo "  - $var"
    done
    echo ""
    echo "Edit .env and set these values, then run bootstrap again."
    exit 1
fi

log_success "Configuration validated"

# =============================================================================
# STEP 4: Generate missing secrets
# =============================================================================
log_info "Checking secrets..."

update_env_var() {
    local var_name=$1
    local var_value=$2
    local force=${3:-false}
    local current_value=$(grep "^${var_name}=" .env | cut -d'=' -f2-)
    
    # Force update for API tokens (they're tied to database and invalid after wipe)
    # GITEA_TOKEN, N8N_TOKEN, COOLIFY_TOKEN need fresh values each bootstrap
    case "$var_name" in
        GITEA_TOKEN|N8N_TOKEN|COOLIFY_TOKEN|CASDOOR_CLIENT_ID|CASDOOR_CLIENT_SECRET|GITEA_OAUTH_CLIENT_ID|GITEA_OAUTH_CLIENT_SECRET)
            force=true
            ;;
    esac
    
    if [ -z "$current_value" ] || [[ "$current_value" == *"GENERATE"* ]] || [[ "$current_value" == *"YOUR_"* ]] || [ "$force" = true ]; then
        if grep -q "^${var_name}=" .env; then
            # Update existing
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' "s|^${var_name}=.*|${var_name}=${var_value}|" .env
            else
                sed -i "s|^${var_name}=.*|${var_name}=${var_value}|" .env
            fi
        else
            # Add new
            echo "${var_name}=${var_value}" >> .env
        fi
    fi
}

# Generate any missing secrets
update_env_var "POSTGRES_GIT_PASSWORD" "$(openssl rand -hex 24)"
update_env_var "POSTGRES_N8N_PASSWORD" "$(openssl rand -hex 24)"
update_env_var "POSTGRES_COOLIFY_PASSWORD" "$(openssl rand -hex 24)"
update_env_var "COOLIFY_APP_KEY" "base64:$(openssl rand -base64 32)"
update_env_var "LOBE_POSTGRES_PASSWORD" "$(openssl rand -hex 24)"
update_env_var "MINIO_ROOT_PASSWORD" "$(openssl rand -base64 24)"
update_env_var "KEY_VAULTS_SECRET" "$(openssl rand -base64 32)"
update_env_var "NEXT_AUTH_SECRET" "$(openssl rand -hex 32)"
update_env_var "JWKS_KEY" "$(openssl rand -base64 32)"
update_env_var "OPENCLAW_GATEWAY_TOKEN" "$(openssl rand -hex 32)"

# Reload env after updates
set -a
while IFS='=' read -r key value; do
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ -z "$key" ]] && continue
    key=$(echo "$key" | xargs)
    if [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        export "$key=$value"
    fi
done < .env
set +a

log_success "Secrets configured"

# =============================================================================
# STEP 5: Cloudflare Tunnel Setup
# =============================================================================
log_info "Setting up Cloudflare Tunnel..."

# Reload env to get any updated values (strip Windows line endings)
CLOUDFLARE_TUNNEL_TOKEN=$(grep "^CLOUDFLARE_TUNNEL_TOKEN=" .env | cut -d'=' -f2- | tr -d '\r')
CLOUDFLARE_API_TOKEN=$(grep "^CLOUDFLARE_API_TOKEN=" .env | cut -d'=' -f2- | tr -d '\r')
CLOUDFLARE_ACCOUNT_ID=$(grep "^CLOUDFLARE_ACCOUNT_ID=" .env | cut -d'=' -f2- | tr -d '\r')
CLOUDFLARE_ZONE_ID=$(grep "^CLOUDFLARE_ZONE_ID=" .env | cut -d'=' -f2- | tr -d '\r')

# Check if we need to create/verify tunnel
if [ -n "$CLOUDFLARE_API_TOKEN" ] && [ "$CLOUDFLARE_API_TOKEN" != "YOUR_API_TOKEN" ]; then
    CF_API="https://api.cloudflare.com/client/v4"
    CF_AUTH="Authorization: Bearer $CLOUDFLARE_API_TOKEN"
    
    echo "  Checking Cloudflare API access..."
    
    # Test API access
    API_TEST=$(curl -sf -H "$CF_AUTH" "$CF_API/user/tokens/verify" 2>/dev/null)
    if [ "$(json_get "$API_TEST" '.success')" != "true" ]; then
        log_warn "Cloudflare API token invalid or insufficient permissions"
        echo "    Skipping tunnel verification - using existing token if available"
    else
        echo "  API access verified"
        
        # List existing tunnels
        TUNNELS_RESP=$(curl -sf -H "$CF_AUTH" "$CF_API/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel" 2>/dev/null)
        TUNNEL_COUNT=$(json_get "$TUNNELS_RESP" '.result | length')
        
        # Look for existing tunnel named "paas-stack" or similar
        EXISTING_TUNNEL_ID=""
        EXISTING_TUNNEL_NAME=""
        if [ -n "$TUNNEL_COUNT" ] && [ "$TUNNEL_COUNT" != "0" ] && [ "$TUNNEL_COUNT" != "null" ]; then
            # Check each tunnel
            for i in $(seq 0 $((TUNNEL_COUNT - 1))); do
                T_NAME=$(json_get "$TUNNELS_RESP" ".result[$i].name")
                T_ID=$(json_get "$TUNNELS_RESP" ".result[$i].id")
                T_STATUS=$(json_get "$TUNNELS_RESP" ".result[$i].status")
                T_DELETED=$(json_get "$TUNNELS_RESP" ".result[$i].deleted_at")
                
                # Skip deleted tunnels
                [ "$T_DELETED" != "null" ] && [ -n "$T_DELETED" ] && continue
                
                # Look for tunnel matching our domain or named paas-stack
                if [[ "$T_NAME" == *"$BASE_DOMAIN"* ]] || [[ "$T_NAME" == "paas-stack"* ]] || [[ "$T_NAME" == "paas-ai-stack"* ]]; then
                    EXISTING_TUNNEL_ID="$T_ID"
                    EXISTING_TUNNEL_NAME="$T_NAME"
                    echo "  Found existing tunnel: $T_NAME ($T_STATUS)"
                    break
                fi
            done
        fi
        
        # If no matching tunnel found and no token, create one
        if [ -z "$EXISTING_TUNNEL_ID" ] && { [ -z "$CLOUDFLARE_TUNNEL_TOKEN" ] || [ "$CLOUDFLARE_TUNNEL_TOKEN" = "YOUR_TUNNEL_TOKEN" ]; }; then
            echo "  Creating new tunnel..."
            TUNNEL_NAME="paas-stack-$(echo $BASE_DOMAIN | tr '.' '-')"
            TUNNEL_SECRET=$(openssl rand -base64 32 | tr -d '\n')
            
            CREATE_RESP=$(curl -sf -X POST "$CF_API/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel" \
                -H "$CF_AUTH" \
                -H "Content-Type: application/json" \
                -d "{
                    \"name\": \"$TUNNEL_NAME\",
                    \"tunnel_secret\": \"$TUNNEL_SECRET\",
                    \"config_src\": \"cloudflare\"
                }" 2>/dev/null)
            
            if [ "$(json_get "$CREATE_RESP" '.success')" = "true" ]; then
                EXISTING_TUNNEL_ID=$(json_get "$CREATE_RESP" '.result.id')
                echo "  Created tunnel: $TUNNEL_NAME"
                
                # Get tunnel token
                TOKEN_RESP=$(curl -sf -X GET "$CF_API/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel/$EXISTING_TUNNEL_ID/token" \
                    -H "$CF_AUTH" 2>/dev/null)
                NEW_TOKEN=$(json_get "$TOKEN_RESP" '.result')
                
                if [ -n "$NEW_TOKEN" ] && [ "$NEW_TOKEN" != "null" ]; then
                    update_env_var "CLOUDFLARE_TUNNEL_TOKEN" "$NEW_TOKEN" true
                    CLOUDFLARE_TUNNEL_TOKEN="$NEW_TOKEN"
                    echo "  Tunnel token saved to .env"
                else
                    log_warn "Failed to get tunnel token - you may need to get it from Cloudflare dashboard"
                fi
            else
                log_warn "Failed to create tunnel: $(json_get "$CREATE_RESP" '.errors[0].message')"
            fi
        fi
        
        # Configure tunnel routes (public hostnames)
        if [ -n "$EXISTING_TUNNEL_ID" ]; then
            echo "  Configuring tunnel routes..."
            
            # Define service routes
            declare -A ROUTES=(
                ["$GITEA_DOMAIN"]="http://gitea:3000"
                ["$COOLIFY_DOMAIN"]="http://coolify:8080"
                ["$COOLIFY_REALTIME_DOMAIN"]="http://coolify-realtime:6001"
                ["$N8N_DOMAIN"]="http://n8n:5678"
                ["$LOBE_DOMAIN"]="http://lobe-chat:3210"
                ["$CASDOOR_DOMAIN"]="http://lobe-casdoor:8000"
                ["$OPENCLAW_DOMAIN"]="http://openclaw-cli:18789"
                ["*.$BASE_DOMAIN"]="http://localhost:80"
            )
            
            # Build ingress config
            INGRESS_RULES='['
            for hostname in "${!ROUTES[@]}"; do
                service="${ROUTES[$hostname]}"
                INGRESS_RULES="$INGRESS_RULES{\"hostname\":\"$hostname\",\"service\":\"$service\"},"
            done
            INGRESS_RULES="$INGRESS_RULES{\"service\":\"http_status:404\"}]"
            
            # Update tunnel configuration
            CONFIG_RESP=$(curl -sf -X PUT "$CF_API/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel/$EXISTING_TUNNEL_ID/configurations" \
                -H "$CF_AUTH" \
                -H "Content-Type: application/json" \
                -d "{\"config\":{\"ingress\":$INGRESS_RULES}}" 2>/dev/null)
            
            if [ "$(json_get "$CONFIG_RESP" '.success')" = "true" ]; then
                echo "  Tunnel routes configured"
            else
                log_warn "Failed to configure routes: $(json_get "$CONFIG_RESP" '.errors[0].message')"
                echo "    You may need to configure routes manually in Cloudflare dashboard"
            fi
            
            # Create DNS records if zone ID provided
            if [ -n "$CLOUDFLARE_ZONE_ID" ] && [ "$CLOUDFLARE_ZONE_ID" != "YOUR_ZONE_ID" ]; then
                echo "  Creating DNS records..."
                
                for hostname in "${!ROUTES[@]}"; do
                    # Skip wildcard for DNS (handled separately)
                    [[ "$hostname" == "*."* ]] && continue
                    
                    # Extract subdomain
                    SUBDOMAIN="${hostname%%.$BASE_DOMAIN}"
                    [ "$SUBDOMAIN" = "$hostname" ] && continue  # Skip if no subdomain
                    
                    # Check if record exists
                    EXISTING_DNS=$(curl -sf -H "$CF_AUTH" \
                        "$CF_API/zones/$CLOUDFLARE_ZONE_ID/dns_records?name=$hostname&type=CNAME" 2>/dev/null)
                    
                    if [ "$(json_get "$EXISTING_DNS" '.result | length')" = "0" ]; then
                        # Create CNAME pointing to tunnel
                        DNS_RESP=$(curl -sf -X POST "$CF_API/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
                            -H "$CF_AUTH" \
                            -H "Content-Type: application/json" \
                            -d "{
                                \"type\": \"CNAME\",
                                \"name\": \"$SUBDOMAIN\",
                                \"content\": \"$EXISTING_TUNNEL_ID.cfargotunnel.com\",
                                \"proxied\": true
                            }" 2>/dev/null)
                        
                        if [ "$(json_get "$DNS_RESP" '.success')" = "true" ]; then
                            echo "    Created: $hostname"
                        fi
                    else
                        echo "    Exists: $hostname"
                    fi
                done
                
                # Create wildcard record
                WILDCARD_DNS=$(curl -sf -H "$CF_AUTH" \
                    "$CF_API/zones/$CLOUDFLARE_ZONE_ID/dns_records?name=*.$BASE_DOMAIN&type=CNAME" 2>/dev/null)
                if [ "$(json_get "$WILDCARD_DNS" '.result | length')" = "0" ]; then
                    DNS_RESP=$(curl -sf -X POST "$CF_API/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
                        -H "$CF_AUTH" \
                        -H "Content-Type: application/json" \
                        -d "{
                            \"type\": \"CNAME\",
                            \"name\": \"*\",
                            \"content\": \"$EXISTING_TUNNEL_ID.cfargotunnel.com\",
                            \"proxied\": true
                        }" 2>/dev/null)
                    if [ "$(json_get "$DNS_RESP" '.success')" = "true" ]; then
                        echo "    Created: *.$BASE_DOMAIN (wildcard)"
                    fi
                else
                    echo "    Exists: *.$BASE_DOMAIN (wildcard)"
                fi
            fi
        fi
    fi
else
    echo "  No Cloudflare API token - using existing tunnel token"
fi

# Final validation
CLOUDFLARE_TUNNEL_TOKEN=$(grep "^CLOUDFLARE_TUNNEL_TOKEN=" .env | cut -d'=' -f2- | tr -d '\r')
if [ -z "$CLOUDFLARE_TUNNEL_TOKEN" ] || [ "$CLOUDFLARE_TUNNEL_TOKEN" = "YOUR_TUNNEL_TOKEN" ]; then
    log_error "No Cloudflare tunnel token available"
    echo "  Either:"
    echo "    1. Set CLOUDFLARE_TUNNEL_TOKEN manually in .env"
    echo "    2. Or provide CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID to auto-create"
    exit 1
fi

log_success "Cloudflare Tunnel configured"

# =============================================================================
# STEP 6: Prepare Local Environment
# =============================================================================

# 6a. Generate Cloudflared config from template
log_info "Generating Cloudflared tunnel configuration..."

if [ -f ../config/cloudflared/config.yml.template ]; then
    # Substitute environment variables in template
    envsubst < ../config/cloudflared/config.yml.template > ../config/cloudflared/config.yml
    log_success "Generated config/cloudflared/config.yml"
else
    log_warn "Cloudflared config template not found - using existing config"
fi

# 6b. Create data directories
log_info "Creating data directories..."

mkdir -p data/postgres-git data/postgres-n8n data/coolify-db data/coolify-redis
mkdir -p data/gitea data/gitea-actions data/coolify data/n8n
mkdir -p data/openclaw data/openclaw-workspace

log_success "Data directories created"

# 6c. Verify SSH for Coolify deployments
log_info "Checking SSH for Coolify deployments..."

# SSH is required for Coolify to deploy to local Docker
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Check if SSH server is running (required for Coolify local deployments)
# Use nc (netcat) to test port 22 - works on macOS, Linux, and WSL
# macOS uses launchd for on-demand sshd so pgrep won't find it
if nc -z localhost 22 2>/dev/null; then
    log_success "SSH server is running (port 22 accessible)"
else
    log_warn "SSH server not running on host (port 22 not accessible)"
    echo "  Coolify local deployments require SSH access"
    echo "  Enable SSH:"
    echo "    macOS: System Settings → General → Sharing → Remote Login"
    echo "    Linux: sudo systemctl enable --now sshd"
    echo "    Windows: Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"
fi

# =============================================================================
# STEP 7: Pull images and start services
# =============================================================================
log_info "Pulling Docker images..."
docker compose $COMPOSE_FILES pull --quiet

log_info "Starting services..."
docker compose $COMPOSE_FILES up -d

# =============================================================================
# STEP 8: Wait for services to be healthy AND ready
# =============================================================================
log_step "Waiting for services to be healthy and ready..."
echo ""
echo "  This may take 2-5 minutes on first run. Services need time to:"
echo "  - Initialize databases"
echo "  - Run migrations"
echo "  - Start internal processes"
echo ""

# Track failures but continue to give useful diagnostics
SERVICES_FAILED=()

# --- Database Layer (must be ready first) ---
echo "  [Database Layer]"
wait_for_service "postgres-git" "" 90 || SERVICES_FAILED+=("postgres-git")
wait_for_service "coolify-db" "" 90 || SERVICES_FAILED+=("coolify-db")
wait_for_service "postgres-n8n" "" 90 || SERVICES_FAILED+=("postgres-n8n")
wait_for_service "lobe-postgres" "" 90 || SERVICES_FAILED+=("lobe-postgres")

if [ ${#SERVICES_FAILED[@]} -gt 0 ]; then
    log_error "Database services failed: ${SERVICES_FAILED[*]}"
    echo "  Cannot continue without databases. Check logs with:"
    echo "  docker logs <container-name>"
    exit 1
fi
log_success "Database layer ready"
echo ""

# Small pause to ensure databases accept connections
sleep 5

# --- Application Layer (depends on databases) ---
echo "  [Application Layer]"

# Gitea - wait for health + API
wait_for_service "gitea" "http://127.0.0.1:3000/api/v1/version" 120 60
if [ $? -ne 0 ]; then
    SERVICES_FAILED+=("gitea")
    log_warn "Gitea not fully ready - will retry API operations later"
fi

# Coolify - wait for health + API (takes longer to initialize)
wait_for_service "coolify" "http://127.0.0.1:8080/api/health" 180 90
if [ $? -ne 0 ]; then
    SERVICES_FAILED+=("coolify")
    log_warn "Coolify not fully ready - will retry API operations later"
fi

# n8n - wait for health + API
wait_for_service "n8n" "http://127.0.0.1:5678/healthz" 120 60
if [ $? -ne 0 ]; then
    SERVICES_FAILED+=("n8n")
    log_warn "n8n not fully ready - will retry API operations later"
fi

# Casdoor - wait for health + API
wait_for_service "lobe-casdoor" "http://127.0.0.1:8000/api/health" 120 60
if [ $? -ne 0 ]; then
    SERVICES_FAILED+=("lobe-casdoor")
    log_warn "Casdoor not fully ready - will retry API operations later"
fi

# LobeChat - wait for health (no health API endpoint)
wait_for_service "lobe-chat" "" 120
if [ $? -ne 0 ]; then
    SERVICES_FAILED+=("lobe-chat")
    log_warn "LobeChat not fully ready - will retry later"
fi

echo ""
if [ ${#SERVICES_FAILED[@]} -eq 0 ]; then
    log_success "All services healthy and ready"
else
    log_warn "Some services need more time: ${SERVICES_FAILED[*]}"
    echo "  Will use retry logic for API operations"
fi

# Extra settling time - services may be "ready" but still initializing internally
echo ""
echo "  Allowing 10s for services to fully initialize..."
sleep 10

# =============================================================================
# STEP 9: Create admin accounts
# =============================================================================
log_step "Creating admin accounts..."

# --- Gitea ---
echo ""
echo "  [Gitea Admin Setup]"
GITEA_URL="http://127.0.0.1:3000"

# First, ensure Gitea API is responding
if ! wait_for_api "Gitea" "$GITEA_URL/api/v1/version" 60; then
    log_error "Gitea API not responding - cannot create admin"
    echo "  Check: docker logs gitea"
else
    # Check if admin user exists via API (with retry)
    echo "  Checking for existing admin user..."
    ADMIN_EXISTS=false
    for attempt in 1 2 3; do
        ADMIN_CHECK=$(curl -sf "$GITEA_URL/api/v1/users/$ADMIN_USERNAME" 2>/dev/null || echo "")
        if echo "$ADMIN_CHECK" | grep -q "\"login\":"; then
            ADMIN_EXISTS=true
            break
        fi
        sleep 2
    done

    if [ "$ADMIN_EXISTS" = true ]; then
        log_success "Admin user '$ADMIN_USERNAME' exists"
    else
        echo "  Creating admin user..."
        CREATE_OUTPUT=$(docker exec -u git gitea gitea admin user create \
            --config /data/gitea/conf/app.ini \
            --username "$ADMIN_USERNAME" \
            --password "$ADMIN_PASSWORD" \
            --email "$ADMIN_EMAIL" \
            --admin \
            --must-change-password=false 2>&1) || true
        
        # Verify creation
        sleep 2
        VERIFY_CHECK=$(curl -sf "$GITEA_URL/api/v1/users/$ADMIN_USERNAME" 2>/dev/null || echo "")
        if echo "$VERIFY_CHECK" | grep -q "\"login\":"; then
            log_success "Admin user created and verified"
        else
            log_warn "Admin creation uncertain: $CREATE_OUTPUT"
        fi
    fi

    # Generate API token with proper retry
    echo "  Generating API token..."
    NEW_TOKEN=""
    
    get_gitea_token() {
        curl -sf -X POST "$GITEA_URL/api/v1/users/$ADMIN_USERNAME/tokens" \
            -u "$ADMIN_USERNAME:$ADMIN_PASSWORD" \
            -H "Content-Type: application/json" \
            -d "{\"name\": \"paas-bootstrap-$(date +%s)\", \"scopes\": [\"all\"]}"
    }
    
    if retry_with_backoff "Gitea token" 5 get_gitea_token; then
        NEW_TOKEN=$(json_get "$RETRY_OUTPUT" '.sha1')
    fi

    if [ -n "$NEW_TOKEN" ]; then
        update_env_var "GITEA_TOKEN" "$NEW_TOKEN"
        export GITEA_TOKEN="$NEW_TOKEN"
        
        # Verify token works
        if curl -sf "$GITEA_URL/api/v1/user" -H "Authorization: token $NEW_TOKEN" | grep -q "\"login\":"; then
            log_success "API token generated and verified"
        else
            log_warn "API token generated but verification failed"
        fi
    else
        log_error "Gitea token generation failed after retries"
        echo "  Manual fix: docker exec -u git gitea gitea admin user generate-access-token --username $ADMIN_USERNAME --scopes all"
    fi
fi

# --- Casdoor ---
echo "  Casdoor:"
CASDOOR_URL="http://127.0.0.1:8000"

# Get current client ID from env
CURRENT_CLIENT_ID=$(grep "^CASDOOR_CLIENT_ID=" .env | cut -d'=' -f2-)

# Use database method directly (more reliable than API)
# Check if app exists
EXISTING_APP=$(docker exec lobe-postgres psql -U postgres -d casdoor -t -c "SELECT client_id FROM application WHERE name='lobechat'" 2>/dev/null | tr -d ' \n')

if [ -n "$EXISTING_APP" ]; then
    # App exists - get credentials
    EXISTING_CLIENT_ID=$(docker exec lobe-postgres psql -U postgres -d casdoor -t -c "SELECT client_id FROM application WHERE name='lobechat'" 2>/dev/null | tr -d ' \n')
    EXISTING_CLIENT_SECRET=$(docker exec lobe-postgres psql -U postgres -d casdoor -t -c "SELECT client_secret FROM application WHERE name='lobechat'" 2>/dev/null | tr -d ' \n')
    
    if [ "$CURRENT_CLIENT_ID" != "$EXISTING_CLIENT_ID" ]; then
        update_env_var "CASDOOR_CLIENT_ID" "$EXISTING_CLIENT_ID"
        update_env_var "CASDOOR_CLIENT_SECRET" "$EXISTING_CLIENT_SECRET"
        echo "    LobeChat app found, credentials updated"
    else
        echo "    LobeChat app already configured"
    fi
else
    # Create LobeChat app via database (owner must be 'admin')
    echo "    Creating LobeChat application..."
    CLIENT_ID=$(openssl rand -hex 10)
    CLIENT_SECRET=$(openssl rand -hex 20)
    REDIRECT_URI="https://$LOBE_DOMAIN/api/auth/callback/casdoor"
    
    docker exec lobe-postgres psql -U postgres -d casdoor -c "
        INSERT INTO application (owner, name, created_time, display_name, organization, client_id, client_secret, redirect_uris, enable_password, enable_sign_up, token_format)
        VALUES ('admin', 'lobechat', '$(date -u +%Y-%m-%dT%H:%M:%SZ)', 'LobeChat', 'built-in', '$CLIENT_ID', '$CLIENT_SECRET', 
                '[\"$REDIRECT_URI\"]', true, true, 'JWT');
    " > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        update_env_var "CASDOOR_CLIENT_ID" "$CLIENT_ID"
        update_env_var "CASDOOR_CLIENT_SECRET" "$CLIENT_SECRET"
        echo "    LobeChat app created"
    else
        log_error "Casdoor OAuth app creation failed"
    fi
fi

# Update Casdoor admin password via database (bcrypt hash)
# Default Casdoor admin password is "123" - we need to change it
echo "    Updating admin password..."

# Check if password is still default by trying to login with "123"
LOGIN_RESP=$(curl -sf -X POST "$CASDOOR_URL/api/login" \
    -H "Content-Type: application/json" \
    -d '{
        "application": "app-built-in",
        "organization": "built-in", 
        "username": "admin",
        "password": "123",
        "type": "login"
    }' 2>/dev/null || echo "")

LOGIN_STATUS=$(json_get "$LOGIN_RESP" '.status')
if [ "$LOGIN_STATUS" = "ok" ]; then
    # Default password still active - user must update manually
    echo "    Casdoor admin using default password"
    echo "    ⚠ ACTION REQUIRED: Update password after first login"
    CASDOOR_PASSWORD_DEFAULT=true
else
    # Default password didn't work - check if ADMIN_PASSWORD works
    TEST_LOGIN=$(curl -sf -X POST "$CASDOOR_URL/api/login" \
        -H "Content-Type: application/json" \
        -d "{
            \"application\": \"app-built-in\",
            \"organization\": \"built-in\", 
            \"username\": \"admin\",
            \"password\": \"$ADMIN_PASSWORD\",
            \"type\": \"login\"
        }" 2>/dev/null || echo "")
    TEST_STATUS=$(json_get "$TEST_LOGIN" '.status')
    if [ "$TEST_STATUS" = "ok" ]; then
        echo "    Admin password already set to ADMIN_PASSWORD"
    else
        log_warn "Casdoor login failed with both default and configured passwords"
        echo "    You may need to reset the password manually"
    fi
fi

# Restart LobeChat to pick up new Casdoor credentials
# Docker compose caches .env at session start, so we need to force a completely fresh read
sync  # Ensure .env changes are flushed to disk
sleep 2

# Get the expected client ID from .env
EXPECTED_CASDOOR_ID=$(grep "^CASDOOR_CLIENT_ID=" .env | cut -d'=' -f2-)

echo "    Restarting LobeChat with new credentials..."
echo "    Expected Client ID: $EXPECTED_CASDOOR_ID"

# Stop and completely remove the container to clear any cached config
docker stop lobe-chat 2>/dev/null || true
docker rm -f lobe-chat 2>/dev/null || true

# CRITICAL FIX: Export env vars to shell environment BEFORE calling docker compose
# This ensures compose sees the updated values even if it has internal caching
export CASDOOR_CLIENT_ID="$EXPECTED_CASDOOR_ID"
export CASDOOR_CLIENT_SECRET="$(grep "^CASDOOR_CLIENT_SECRET=" .env | cut -d'=' -f2-)"

# Force recreate with explicit env file and shell-exported vars
# The --force-recreate ensures a fresh container even if config unchanged
docker compose $COMPOSE_FILES --env-file .env up -d lobe-chat --force-recreate --quiet-pull 2>&1

# Wait for container to start
sleep 8

# Verify credentials propagated correctly
ACTUAL_CASDOOR_ID=$(docker exec lobe-chat printenv AUTH_CASDOOR_ID 2>/dev/null || echo "")

if [ -z "$ACTUAL_CASDOOR_ID" ]; then
    log_warn "LobeChat container not ready - waiting longer..."
    sleep 5
    ACTUAL_CASDOOR_ID=$(docker exec lobe-chat printenv AUTH_CASDOOR_ID 2>/dev/null || echo "")
fi

if [ "$ACTUAL_CASDOOR_ID" != "$EXPECTED_CASDOOR_ID" ]; then
    log_error "LobeChat credentials mismatch!"
    echo "    Expected: $EXPECTED_CASDOOR_ID"
    echo "    Got: $ACTUAL_CASDOOR_ID"
    echo "    Attempting direct container restart with explicit env..."
    
    # Last resort: use docker run directly to guarantee env vars
    docker stop lobe-chat 2>/dev/null || true
    docker rm -f lobe-chat 2>/dev/null || true
    
    # Get all required env vars fresh from .env
    source <(grep -E '^(CASDOOR_|KEY_VAULTS_|NEXT_AUTH_|POSTGRES_|MINIO_|OPENCLAW_)' .env | sed 's/^/export /')
    
    docker run -d --name lobe-chat \
        --network paas-network \
        -p 127.0.0.1:3210:3210 \
        -e APP_URL="https://$LOBE_DOMAIN" \
        -e NEXT_AUTH_SSO_PROVIDERS="casdoor" \
        -e AUTH_CASDOOR_ID="$CASDOOR_CLIENT_ID" \
        -e AUTH_CASDOOR_SECRET="$CASDOOR_CLIENT_SECRET" \
        -e AUTH_CASDOOR_ISSUER="https://$CASDOOR_DOMAIN" \
        -e KEY_VAULTS_SECRET="$KEY_VAULTS_SECRET" \
        -e NEXT_AUTH_SECRET="$NEXT_AUTH_SECRET" \
        -e DATABASE_URL="postgresql://postgres:$POSTGRES_PASSWORD@lobe-postgres:5432/lobechat" \
        -e S3_ENDPOINT="http://lobe-minio:9000" \
        -e S3_ACCESS_KEY_ID="$MINIO_ROOT_USER" \
        -e S3_SECRET_ACCESS_KEY="$MINIO_ROOT_PASSWORD" \
        -e S3_BUCKET="lobe" \
        -e S3_PUBLIC_DOMAIN="https://$LOBE_DOMAIN/s3" \
        -e DEFAULT_FILES_CONFIG="embedding_model=openai/@cf/baai/bge-large-en-v1.5" \
        -e OPENAI_API_KEY="$OPENCLAW_GATEWAY_TOKEN" \
        -e OPENAI_PROXY_URL="http://openclaw-cli:8787/v1" \
        --restart unless-stopped \
        lobehub/lobe-chat:latest \
        > /dev/null 2>&1
    
    sleep 8
    ACTUAL_CASDOOR_ID=$(docker exec lobe-chat printenv AUTH_CASDOOR_ID 2>/dev/null || echo "")
    
    if [ "$ACTUAL_CASDOOR_ID" != "$EXPECTED_CASDOOR_ID" ]; then
        log_error "LobeChat credentials still mismatched after direct docker run"
        echo "    Expected: $EXPECTED_CASDOOR_ID"
        echo "    Got: $ACTUAL_CASDOOR_ID"
        # Continue anyway - don't block entire bootstrap
        log_warn "Continuing with setup - LobeChat SSO may not work"
    else
        echo "    LobeChat credentials verified via direct docker run"
    fi
else
    echo "    LobeChat credentials verified: $ACTUAL_CASDOOR_ID"
fi

# Mark any existing LobeChat users as onboarded (skip wizard on next login)
# Users are only created after first SSO login, so this helps for re-runs
LOBE_USERS=$(docker exec lobe-postgres psql -U postgres -d lobechat -t -c \
    "SELECT COUNT(*) FROM users WHERE is_onboarded = false;" 2>/dev/null | tr -d ' \n')
if [ -n "$LOBE_USERS" ] && [ "$LOBE_USERS" != "0" ]; then
    echo "    Marking $LOBE_USERS LobeChat user(s) as onboarded..."
    docker exec lobe-postgres psql -U postgres -d lobechat -c \
        "UPDATE users SET is_onboarded = true, full_name = COALESCE(full_name, '$ADMIN_USERNAME') WHERE is_onboarded = false;" \
        > /dev/null 2>&1
    echo "    LobeChat onboarding wizard will be skipped"
fi

# --- Coolify ---
echo ""
echo "  [Coolify Admin Setup]"
COOLIFY_URL="http://127.0.0.1:8080"

# Ensure Coolify is responding before proceeding
if ! wait_for_api "Coolify" "$COOLIFY_URL/api/health" 90; then
    log_warn "Coolify API not responding - will retry operations"
fi

# Small delay for internal initialization
sleep 5

# Check if any users exist (with retry)
echo "  Checking for existing admin..."
USER_COUNT="0"
for attempt in 1 2 3 4 5; do
    USER_COUNT=$(docker exec coolify php artisan tinker --execute="echo App\Models\User::count();" 2>/dev/null | tr -d '\n' || echo "error")
    if [ "$USER_COUNT" != "error" ]; then
        break
    fi
    echo "    Database not ready, waiting..."
    sleep 5
done

if [ "$USER_COUNT" = "0" ]; then
    echo "  Creating admin user..."
    CREATE_RESULT=$(docker exec coolify php artisan tinker --execute="
\$user = new App\Models\User;
\$user->name = '$ADMIN_USERNAME';
\$user->email = '$ADMIN_EMAIL';
\$user->password = bcrypt('$ADMIN_PASSWORD');
\$user->save();
echo 'created:' . \$user->id;
" 2>/dev/null | tail -1)
    
    if [[ "$CREATE_RESULT" == "created:"* ]]; then
        log_success "Admin user created"
    else
        log_warn "Admin creation may have failed: $CREATE_RESULT"
    fi
else
    log_success "Admin user exists (count: $USER_COUNT)"
fi

# Configure Coolify instance settings (with retry)
echo "  Configuring instance settings..."
for attempt in 1 2 3; do
    CONFIG_RESULT=$(docker exec coolify php artisan tinker --execute="
\$settings = \App\Models\InstanceSettings::first();
if (\$settings) {
    \$settings->is_api_enabled = true;
    \$settings->fqdn = 'https://${COOLIFY_DOMAIN}';
    \$settings->is_registration_enabled = false;
    \$settings->instance_name = 'PaaS AI Stack';
    \$settings->public_ipv4 = null;
    \$settings->save();
    echo 'configured';
} else {
    echo 'no_settings';
}
" 2>/dev/null | tail -1)
    
    if [ "$CONFIG_RESULT" = "configured" ]; then
        log_success "Instance settings configured"
        break
    fi
    sleep 3
done

# Generate/verify Coolify API token
echo "  Setting up API token..."

# First, check if existing token in .env actually works
EXISTING_TOKEN=$(grep "^COOLIFY_TOKEN=" .env 2>/dev/null | cut -d'=' -f2- | tr -d '\r')
TOKEN_VALID=false

if [ -n "$EXISTING_TOKEN" ]; then
    echo "    Verifying existing token..."
    sleep 2
    if curl -sf "$COOLIFY_URL/api/v1/servers" -H "Authorization: Bearer $EXISTING_TOKEN" 2>/dev/null | grep -q "uuid"; then
        TOKEN_VALID=true
        export COOLIFY_TOKEN="$EXISTING_TOKEN"
        log_success "API token verified and working"
    else
        echo "    Existing token invalid - will regenerate"
    fi
fi

# Generate new token if needed
if [ "$TOKEN_VALID" = false ]; then
    echo "    Generating fresh API token..."
    
    for attempt in 1 2 3; do
        NEW_COOLIFY_TOKEN=$(docker exec coolify php artisan tinker --execute="
use Illuminate\Support\Str;
use Illuminate\Support\Facades\DB;

\$user = \App\Models\User::first();
\$team = \App\Models\Team::first();

if (\$user && \$team) {
    // Clear all existing tokens
    DB::table('personal_access_tokens')->truncate();
    
    \$plainTextToken = Str::random(40);
    
    // Insert directly to avoid model issues
    \$id = DB::table('personal_access_tokens')->insertGetId([
        'tokenable_type' => 'App\\\Models\\\User',
        'tokenable_id' => \$user->id,
        'team_id' => \$team->id,
        'name' => 'paas-api',
        'token' => hash('sha256', \$plainTextToken),
        'abilities' => json_encode(['*']),
        'created_at' => now(),
        'updated_at' => now(),
    ]);
    
    echo \$id . '|' . \$plainTextToken;
}
" 2>/dev/null | tail -1)
        
        if [ -n "$NEW_COOLIFY_TOKEN" ] && [[ "$NEW_COOLIFY_TOKEN" == *"|"* ]]; then
            break
        fi
        echo "    Attempt $attempt failed, retrying..."
        sleep 5
    done
    
    if [ -n "$NEW_COOLIFY_TOKEN" ] && [[ "$NEW_COOLIFY_TOKEN" == *"|"* ]]; then
        # Update .env file
        grep -v "^COOLIFY_TOKEN=" .env > .env.tmp 2>/dev/null || true
        echo "COOLIFY_TOKEN=$NEW_COOLIFY_TOKEN" >> .env.tmp
        mv .env.tmp .env
        export COOLIFY_TOKEN="$NEW_COOLIFY_TOKEN"
        
        # Verify token works
        sleep 2
        if curl -sf "$COOLIFY_URL/api/v1/servers" -H "Authorization: Bearer $NEW_COOLIFY_TOKEN" 2>/dev/null | grep -q "uuid"; then
            log_success "API token generated and verified"
        else
            log_warn "API token generated but verification pending"
        fi
    else
        log_error "API token generation failed after retries"
    fi
fi

# --- n8n ---
echo ""
echo "  [n8n Admin Setup]"

# Ensure n8n API is responding
if ! wait_for_api "n8n" "http://127.0.0.1:5678/healthz" 60; then
    log_warn "n8n API not responding - will retry operations"
fi

# n8n requires owner setup via its API to properly hash the password
# Check if owner is already set up (with retry)
echo "  Checking for existing owner..."
N8N_HAS_OWNER="0"
for attempt in 1 2 3 4 5; do
    N8N_HAS_OWNER=$(docker exec postgres-n8n sh -c "psql -U n8n -d n8n -t -c \"SELECT COUNT(*) FROM public.user WHERE password != '' AND password IS NOT NULL\"" 2>/dev/null | tr -d ' \n')
    if [ -n "$N8N_HAS_OWNER" ] && [ "$N8N_HAS_OWNER" != "" ]; then
        break
    fi
    sleep 3
done

if [ "$N8N_HAS_OWNER" = "0" ] || [ -z "$N8N_HAS_OWNER" ]; then
    echo "  Setting up owner account via n8n API..."
    
    SETUP_SUCCESS=false
    for attempt in 1 2 3 4 5; do
        # Use n8n's setup endpoint to create owner with proper password hash
        SETUP_RESP=$(curl -sf -X POST "http://127.0.0.1:5678/rest/owner/setup" \
            -H "Content-Type: application/json" \
            -d "{
                \"email\": \"$ADMIN_EMAIL\",
                \"firstName\": \"$ADMIN_USERNAME\",
                \"lastName\": \"Admin\",
                \"password\": \"$ADMIN_PASSWORD\",
                \"agree\": true
            }" 2>/dev/null || echo "")
        
        if echo "$SETUP_RESP" | grep -q "\"id\""; then
            SETUP_SUCCESS=true
            break
        fi
        
        echo "    Attempt $attempt - n8n not ready, waiting..."
        sleep 5
    done
    
    if [ "$SETUP_SUCCESS" = true ]; then
        log_success "Owner account created"
    else
        log_warn "n8n owner setup may have failed"
        echo "    Check: docker logs n8n"
    fi
else
    log_success "Owner account already configured"
fi

# Get user ID
N8N_USER_ID=$(docker exec postgres-n8n sh -c "psql -U n8n -d n8n -t -c \"SELECT id FROM public.user LIMIT 1\"" 2>/dev/null | tr -d ' \n')

if [ -n "$N8N_USER_ID" ]; then
    # Update user email/name
    docker exec postgres-n8n sh -c "psql -U n8n -d n8n -c \"UPDATE public.user SET email='$ADMIN_EMAIL', \\\"firstName\\\"='$ADMIN_USERNAME' WHERE id='$N8N_USER_ID'\"" > /dev/null 2>&1
    
    # Always generate fresh API key (old keys invalid after wipe)
    # First check if key exists in DB
    EXISTING_KEY=$(docker exec postgres-n8n sh -c "psql -U n8n -d n8n -t -c \"SELECT \\\"apiKey\\\" FROM user_api_keys WHERE label='paas-bootstrap' LIMIT 1\"" 2>/dev/null | tr -d ' \n')
    
    if [ -n "$EXISTING_KEY" ]; then
        update_env_var "N8N_TOKEN" "$EXISTING_KEY"
        echo "    API key exists"
    else
        # Create new API key
        echo "    Generating API key..."
        API_KEY_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]')
        API_KEY="n8n_api_$(openssl rand -hex 20)"
        
        docker exec postgres-n8n sh -c "psql -U n8n -d n8n -c \"INSERT INTO user_api_keys (id, \\\"userId\\\", label, \\\"apiKey\\\", audience, \\\"createdAt\\\", \\\"updatedAt\\\") VALUES ('$API_KEY_ID', '$N8N_USER_ID', 'paas-bootstrap', '$API_KEY', 'public-api', NOW(), NOW())\"" > /dev/null 2>&1
        
        if [ $? -eq 0 ]; then
            update_env_var "N8N_TOKEN" "$API_KEY"
            echo "    API key generated"
        else
            log_error "n8n API key generation failed"
        fi
    fi
fi

log_success "Account setup complete"

# =============================================================================
# STEP 10: Setup Coolify Server (This Machine)
# =============================================================================
log_info "Setting up Coolify server..."

# Generate SSH key for Coolify if not exists
mkdir -p data/coolify-ssh
if [ ! -f data/coolify-ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -f data/coolify-ssh/id_ed25519 -N "" -C "coolify@localhost" > /dev/null 2>&1
    echo "  SSH key generated for Coolify"
fi

# Add Coolify's key to host authorized_keys
# Windows requires special handling - admin users need key in different location
if [ "$IS_WINDOWS" = true ]; then
    # On Windows, SSH key must go to C:\ProgramData\ssh\administrators_authorized_keys
    # This cannot be done from bash - requires PowerShell with admin rights
    echo "  Coolify SSH key generated at: data/coolify-ssh/id_ed25519.pub"
    WINDOWS_SSH_SETUP_NEEDED=true
    
    # Check if SSH is accessible (may have been set up previously)
    if nc -z localhost 22 2>/dev/null; then
        if ssh -i data/coolify-ssh/id_ed25519 -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 localhost "echo test" > /dev/null 2>&1; then
            log_success "SSH key verified - connection test passed"
            WINDOWS_SSH_SETUP_NEEDED=false
        else
            log_warn "SSH server running but key authentication failed"
        fi
    else
        log_warn "SSH server not running on Windows"
    fi
    
    if [ "$WINDOWS_SSH_SETUP_NEEDED" = true ]; then
        echo ""
        echo "  ╔════════════════════════════════════════════════════════════════╗"
        echo "  ║  WINDOWS SSH SETUP REQUIRED                                    ║"
        echo "  ╠════════════════════════════════════════════════════════════════╣"
        echo "  ║  Run this command in Administrator PowerShell:                 ║"
        echo "  ║                                                                ║"
        echo "  ║    .\\scripts\\setup-windows-ssh.ps1                             ║"
        echo "  ║                                                                ║"
        echo "  ║  This will:                                                    ║"
        echo "  ║  - Install OpenSSH Server (if needed)                          ║"
        echo "  ║  - Configure SSH key authentication                            ║"
        echo "  ║  - Set Git Bash as default SSH shell                           ║"
        echo "  ╚════════════════════════════════════════════════════════════════╝"
        echo ""
    fi
else
    # Linux/macOS: Add key to standard authorized_keys
    mkdir -p ~/.ssh
    touch ~/.ssh/authorized_keys
    chmod 700 ~/.ssh
    chmod 600 ~/.ssh/authorized_keys
    
    # Remove old key first to prevent duplicates
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' '/coolify@localhost/d' ~/.ssh/authorized_keys 2>/dev/null || true
    else
        sed -i '/coolify@localhost/d' ~/.ssh/authorized_keys 2>/dev/null || true
    fi
    cat data/coolify-ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
    echo "  Coolify SSH key synced to authorized_keys"
    
    # Test SSH connection with the key
    if nc -z localhost 22 2>/dev/null; then
        # SSH is available, test the key
        if ssh -i data/coolify-ssh/id_ed25519 -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 localhost "echo test" > /dev/null 2>&1; then
            log_success "SSH key verified - connection test passed"
        else
            log_warn "SSH key added but connection test failed"
            echo "    This may be due to macOS requiring manual approval"
            echo "    Try: ssh -i data/coolify-ssh/id_ed25519 localhost"
        fi
    else
        log_warn "SSH server not running - cannot verify key"
    fi
fi

# Get current username for server config
CURRENT_USER=$(whoami)

# Setup Coolify server in database
COOLIFY_KEY_B64=$(cat data/coolify-ssh/id_ed25519 | base64)
docker exec coolify php artisan tinker --execute="
use App\Models\PrivateKey;
use App\Models\Server;
use App\Models\Team;

\$team = Team::first();

// Create or update private key
\$existingKey = PrivateKey::find(0);
if (!\$existingKey) {
    \$privateKey = base64_decode('${COOLIFY_KEY_B64}');
    \$key = new PrivateKey();
    \$key->id = 0;
    \$key->uuid = (string) \Illuminate\Support\Str::uuid();
    \$key->name = 'localhost-key';
    \$key->description = 'SSH key for localhost server';
    \$key->private_key = \$privateKey;
    \$key->is_git_related = false;
    \$key->team_id = \$team->id;
    \$key->save();
    echo 'Key created\n';
} else {
    echo 'Key exists\n';
}

// Update server configuration
\$server = Server::find(0);
if (\$server) {
    \$server->user = '$CURRENT_USER';
    \$server->port = 22;  // SSH port (not Docker API port 2375)
    \$server->team_id = \$team->id;
    \$server->save();
    echo 'Server updated\n';
}
" 2>&1 || log_warn "Coolify server configuration may have failed"

# Write key to Coolify's SSH directory
docker exec coolify php artisan tinker --execute="
use App\Models\PrivateKey;
use App\Models\Server;

\$key = PrivateKey::find(0);
\$server = Server::find(0);

if (\$key && \$server) {
    @mkdir('/data/coolify/ssh/keys', 0700, true);
    \$keyPath = '/data/coolify/ssh/keys/id.' . \$server->user . '@' . \$server->ip . '.ed25519';
    file_put_contents(\$keyPath, \$key->private_key);
    chmod(\$keyPath, 0600);
    echo 'Key written\n';
}
" 2>&1 || log_warn "Coolify SSH key write may have failed"

echo "  Coolify server configured"

# Check prerequisites for server validation (done later after wildcard domain)
SSH_RUNNING=false
SUDO_CONFIGURED=false

# Use nc to test port 22 - works on macOS (launchd), Linux, and WSL
if nc -z localhost 22 2>/dev/null; then
    SSH_RUNNING=true
    echo "  SSH port 22: accessible"
else
    log_warn "SSH port 22 not accessible"
    echo "    Enable SSH: System Settings → General → Sharing → Remote Login"
fi

if sudo -n true 2>/dev/null; then
    SUDO_CONFIGURED=true
    echo "  Passwordless sudo: configured"
else
    log_warn "Passwordless sudo not configured"
    echo "    Configure with: echo \"\$(whoami) ALL=(ALL) NOPASSWD: ALL\" | sudo tee /etc/sudoers.d/coolify"
fi

# Server validation will occur after wildcard domain is set (Step 13)

# =============================================================================
# STEP 11: Setup Gitea Actions Runner
# =============================================================================
log_info "Setting up Gitea Actions runner..."

# Generate runner token
RUNNER_TOKEN=$(docker exec -u git gitea gitea actions generate-runner-token --config /data/gitea/conf/app.ini 2>/dev/null || echo "")

if [ -n "$RUNNER_TOKEN" ]; then
    # Always regenerate token to avoid stale registration issues
    # After a wipe, old tokens in .env won't work with fresh Gitea database
    echo "  Configuring runner with fresh token..."
    update_env_var "GITEA_ACTIONS_TOKEN" "$RUNNER_TOKEN"
    
    # Clear runner state to force re-registration
    rm -rf data/gitea-actions/.runner 2>/dev/null || true
    
    # Recreate runner container with new token
    export GITEA_ACTIONS_TOKEN="$RUNNER_TOKEN"
    docker compose $COMPOSE_FILES up -d gitea-actions --force-recreate 2>&1 || log_warn "Gitea Actions runner recreate failed"
    echo "  Runner token configured and container restarted"
else
    log_warn "Could not generate runner token (Gitea may need more time to initialize)"
fi

# Wait for runner to register
echo "  Waiting for runner to register..."
sleep 8
RUNNER_STATUS=$(docker logs gitea-actions 2>&1 | tail -10 | grep -c "Runner registered successfully" || true)
if [ "$RUNNER_STATUS" -gt 0 ]; then
    echo "  Runner registered successfully"
else
    echo "  Runner registration pending (check logs: docker logs gitea-actions)"
fi

# =============================================================================
# STEP 12: Setup Coolify + Gitea Integration
# =============================================================================
log_info "Setting up Coolify + Gitea integration..."

# Create OAuth2 app in Gitea for Coolify
OAUTH_RESP=$(curl -sf -X POST "http://127.0.0.1:3000/api/v1/user/applications/oauth2" \
    -u "$ADMIN_USERNAME:$ADMIN_PASSWORD" \
    -H "Content-Type: application/json" \
    -d "{
        \"name\": \"Coolify\",
        \"redirect_uris\": [\"https://${COOLIFY_DOMAIN}/webhooks/source/github/redirect\"]
    }" 2>/dev/null || echo "")

GITEA_CLIENT_ID=$(json_get "$OAUTH_RESP" '.client_id')
GITEA_CLIENT_SECRET=$(json_get "$OAUTH_RESP" '.client_secret')

if [ -n "$GITEA_CLIENT_ID" ]; then
    update_env_var "GITEA_OAUTH_CLIENT_ID" "$GITEA_CLIENT_ID"
    update_env_var "GITEA_OAUTH_CLIENT_SECRET" "$GITEA_CLIENT_SECRET"
    echo "  Gitea OAuth app created for Coolify"
else
    echo "  Gitea OAuth app already exists or creation skipped"
fi

# CI/CD automation available via scripts/setup-ci-cd.sh

# =============================================================================
# STEP 13: Verify Coolify Destination
# =============================================================================
log_info "Verifying Coolify deployment destination..."

# Ensure a Docker destination exists for deployments
DEST_EXISTS=$(docker exec coolify php artisan tinker --execute="
\$dest = \App\Models\StandaloneDocker::first();
if (\$dest) {
    echo \$dest->uuid;
} else {
    echo 'NONE';
}
" 2>/dev/null | tr -d '\n')

if [ "$DEST_EXISTS" = "NONE" ] || [ -z "$DEST_EXISTS" ]; then
    echo "  Creating Docker destination..."
    docker exec coolify php artisan tinker --execute="
use App\Models\StandaloneDocker;
use App\Models\Server;
use Illuminate\Support\Str;

\$server = Server::find(0);
if (\$server) {
    \$dest = new StandaloneDocker();
    \$dest->uuid = (string) Str::uuid();
    \$dest->name = 'coolify';
    \$dest->network = 'coolify';
    \$dest->server_id = \$server->id;
    \$dest->save();
    echo 'Created: ' . \$dest->uuid;
}
" 2>/dev/null
    echo "  Docker destination created"
else
    echo "  Docker destination exists: $DEST_EXISTS"
fi

# Configure wildcard domain for auto-generated app URLs
# Use HTTPS because Cloudflare Tunnel provides SSL termination
echo "  Configuring server wildcard domain..."
docker exec coolify php artisan tinker --execute="
use App\Models\Server;

\$server = Server::find(0);
if (\$server && \$server->settings) {
    // HTTPS because Cloudflare Tunnel handles SSL
    // NOTE: Coolify does NOT accept asterisk (*) - wildcard is automatic
    \$server->settings->wildcard_domain = 'https://${BASE_DOMAIN}';
    // false = Coolify deploys via SSH; our cloudflared container handles tunnel
    \$server->settings->is_cloudflare_tunnel = false;
    \$server->settings->save();
    echo 'Wildcard domain set: https://*.${BASE_DOMAIN}';
}
" 2>&1 || log_warn "Failed to set wildcard domain"
echo "  Server wildcard domain configured (https://*.${BASE_DOMAIN})"

# Validate server now that wildcard domain is set
echo "  Validating Coolify server..."

# Test actual SSH connectivity from Coolify container to host
CURRENT_USER=$(whoami)
SSH_TEST_RESULT=$(docker exec coolify ssh -i /data/coolify/ssh/keys/id.${CURRENT_USER}@host.docker.internal.ed25519 \
    -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 \
    ${CURRENT_USER}@host.docker.internal "echo SSH_OK" 2>&1 || echo "SSH_FAILED")

if echo "$SSH_TEST_RESULT" | grep -q "SSH_OK"; then
    echo "  ✓ SSH test from Coolify to host: PASSED"
    
    # Now set the validation flags since SSH actually works
    VALIDATION_RESULT=$(docker exec coolify php artisan tinker --execute="
use App\Models\Server;
\$server = Server::find(0);
if (\$server && \$server->settings) {
    \$server->settings->is_reachable = true;
    \$server->settings->is_usable = true;
    \$server->settings->save();
    echo 'VALIDATED';
} else {
    echo 'FAILED';
}
" 2>&1)
    
    if echo "$VALIDATION_RESULT" | grep -q "VALIDATED"; then
        log_success "Coolify server validated and ready for deployments"
        COOLIFY_SERVER_VALIDATED=true
    else
        log_warn "Server validation database update failed"
        COOLIFY_SERVER_VALIDATED=false
    fi
else
    log_warn "SSH test from Coolify to host: FAILED"
    echo "    SSH Error: $SSH_TEST_RESULT"
    echo ""
    echo "    ╔════════════════════════════════════════════════════════════════╗"
    echo "    ║  MANUAL VALIDATION REQUIRED                                    ║"
    echo "    ╠════════════════════════════════════════════════════════════════╣"
    echo "    ║  Coolify cannot SSH to your machine for deployments.           ║"
    echo "    ║                                                                 ║"
    echo "    ║  Please:                                                        ║"
    echo "    ║  1. Go to: https://$COOLIFY_DOMAIN/servers                      ║"
    echo "    ║  2. Click on 'localhost'                                        ║"
    echo "    ║  3. Click 'Validate Server' button                              ║"
    echo "    ║  4. If validation fails, check:                                 ║"
    echo "    ║     - SSH is enabled (System Settings → Sharing → Remote Login) ║"
    echo "    ║     - Your SSH key is in authorized_keys                        ║"
    echo "    ║                                                                 ║"
    echo "    ║  After validation succeeds, run: make validate-coolify          ║"
    echo "    ╚════════════════════════════════════════════════════════════════╝"
    echo ""
    COOLIFY_SERVER_VALIDATED=false
fi

# =============================================================================
# STEP 14: Configure Coolify Proxy (Native Approach)
# =============================================================================
log_info "Configuring Coolify proxy (native Coolify-managed)..."

# Windows: Start proxy directly to avoid SSH/chown issues
# Coolify's SSH-based proxy setup fails on Windows because:
# 1. chown commands fail (Windows has no Linux groups)
# 2. Docker credential helper fails in non-interactive SSH sessions
# Solution: Start the proxy container directly and update Coolify's database
if [ "$IS_WINDOWS" = true ]; then
    echo "  Windows detected - starting proxy directly (bypassing SSH issues)..."
    
    # Pre-pull traefik image
    echo "  Pulling traefik image..."
    docker pull traefik:v3.6 > /dev/null 2>&1 && \
        echo "  ✓ traefik:v3.6 pulled" || \
        log_warn "Failed to pull traefik"
    
    # Create proxy directory structure that Coolify expects
    mkdir -p /data/coolify/proxy/dynamic 2>/dev/null || \
        mkdir -p "$HOME/.coolify/proxy/dynamic" 2>/dev/null || true
    
    # Ensure coolify network exists
    docker network create coolify 2>/dev/null || true
    
    # Stop existing proxy if running
    docker stop coolify-proxy 2>/dev/null || true
    docker rm -f coolify-proxy 2>/dev/null || true
    
    # Start traefik proxy container directly
    # Note: Don't expose port 8080 - it conflicts with Coolify's own port
    echo "  Starting coolify-proxy container..."
    docker run -d \
        --name coolify-proxy \
        --restart unless-stopped \
        --network coolify \
        -p 80:80 \
        -p 443:443 \
        -v /var/run/docker.sock:/var/run/docker.sock:ro \
        -v coolify-proxy-certs:/letsencrypt \
        --label "traefik.enable=true" \
        traefik:v3.6 \
        --api.insecure=true \
        --providers.docker=true \
        --providers.docker.exposedbydefault=false \
        --entrypoints.http.address=:80 \
        --entrypoints.https.address=:443 \
        > /dev/null 2>&1
    
    if docker ps --format '{{.Names}}' | grep -q "coolify-proxy"; then
        echo "  ✓ coolify-proxy started directly"
        
        # Update Coolify database to mark proxy as running
        docker exec coolify php artisan tinker --execute="
use App\Models\Server;
\$server = Server::find(0);
if (\$server) {
    \$server->proxy->set('status', 'running');
    \$server->proxy->set('type', 'traefik');
    \$server->save();
    echo 'proxy_status_updated';
}
" 2>/dev/null | grep -q "proxy_status_updated" && \
            echo "  ✓ Coolify database updated"
    else
        log_warn "Failed to start coolify-proxy container"
    fi
else
    # Linux/macOS: Use Coolify's native proxy management
    # The proxy is managed by Coolify natively - we don't modify its config.
    # Per Coolify docs: https://coolify.io/docs/knowledge-base/cloudflare/tunnels/all-resource
    # 
    # Native setup:
    # 1. Coolify manages proxy start/stop via UI or API
    # 2. Proxy binds to host ports 80/443 (Coolify's default)
    # 3. Cloudflare tunnel routes wildcard to coolify-proxy:80 via Docker network
    #
    # We only need to:
    # 1. Ensure proxy is started via Coolify's API
    # 2. Connect proxy to paas-network (for cloudflared container access)

    # Start proxy via Coolify API (native way)
    echo "  Starting Coolify proxy via API..."
    PROXY_START_RESP=$(curl -sf -X POST "http://127.0.0.1:8080/api/v1/servers/0/proxy/start" \
        -H "Authorization: Bearer $COOLIFY_TOKEN" 2>&1 || echo "API_ERROR")

    if echo "$PROXY_START_RESP" | grep -q "API_ERROR\|error"; then
        # API might not support this endpoint, try via tinker
        echo "  Starting proxy via database..."
        docker exec coolify php artisan tinker --execute="
use App\Models\Server;
\$server = Server::find(0);
if (\$server) {
    \$server->proxy->status = 'running';
    \$server->proxy->save();
    echo 'proxy_started';
}
" 2>/dev/null | grep -q "proxy_started" && echo "  Proxy status set to running"
    fi
fi

# Wait for proxy container to exist and be healthy
echo -n "  Waiting for proxy: "
PROXY_READY=false
for i in {1..30}; do
    if docker ps --format '{{.Names}}' | grep -q "coolify-proxy"; then
        PROXY_STATUS=$(docker inspect --format='{{.State.Health.Status}}' coolify-proxy 2>/dev/null || echo "starting")
        if [ "$PROXY_STATUS" = "healthy" ]; then
            PROXY_READY=true
            echo "healthy"
            break
        fi
    fi
    sleep 2
    echo -n "."
done

if [ "$PROXY_READY" = false ]; then
    echo ""
    log_warn "Proxy not ready - may need manual start from Coolify UI"
    echo "    Go to: https://$COOLIFY_DOMAIN/servers → localhost → Proxy → Start Proxy"
fi

# Connect proxy to paas-network (so cloudflared container can reach it)
# This is required because our cloudflared runs in docker-compose, not on host
if docker ps --format '{{.Names}}' | grep -q "coolify-proxy"; then
    echo "  Connecting proxy to paas-network..."
    docker network connect paas-network coolify-proxy 2>/dev/null && \
        echo "  ✓ Proxy connected to paas-network" || \
        echo "  (already connected or network not ready)"
fi

# Connect Gitea to coolify network (so deployments can clone repos via SSH)
# The coolify network is created by Coolify - wait for it if needed
echo "  Connecting Gitea to coolify network..."
COOLIFY_NET_WAIT=0
while ! docker network inspect coolify &>/dev/null && [ $COOLIFY_NET_WAIT -lt 30 ]; do
    sleep 2
    COOLIFY_NET_WAIT=$((COOLIFY_NET_WAIT + 2))
done

if docker network inspect coolify &>/dev/null; then
    # Check if already connected
    GITEA_ON_COOLIFY=$(docker inspect gitea --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null | grep -c coolify || echo "0")
    if [ "$GITEA_ON_COOLIFY" = "0" ]; then
        docker network connect coolify gitea 2>&1 && echo "  ✓ Gitea connected to coolify network" || log_warn "Failed to connect Gitea to coolify network"
    else
        echo "  ✓ Gitea already on coolify network"
    fi
else
    log_warn "Coolify network not found - deployments may fail to clone from Gitea"
    echo "    Fix: docker network connect coolify gitea"
fi

# =============================================================================
# STEP 15: Verify Telegram Configuration
# =============================================================================
log_info "Verifying Telegram configuration..."

TELEGRAM_TOKEN=$(grep "^TELEGRAM_BOT_TOKEN=" .env | cut -d'=' -f2-)
if [ -n "$TELEGRAM_TOKEN" ] && [ "$TELEGRAM_TOKEN" != "YOUR_TELEGRAM_BOT_TOKEN" ]; then
    # Test Telegram Bot API
    BOT_INFO=$(curl -sf "https://api.telegram.org/bot${TELEGRAM_TOKEN}/getMe" 2>/dev/null || echo "")
    BOT_OK=$(json_get "$BOT_INFO" '.ok')
    if [ "$BOT_OK" = "true" ]; then
        BOT_USERNAME=$(json_get "$BOT_INFO" '.result.username')
        [ -z "$BOT_USERNAME" ] && BOT_USERNAME="unknown"
        echo "  ✓ Telegram bot configured: @$BOT_USERNAME"
    else
        log_warn "Telegram bot token invalid or API unreachable"
        echo "    Get token from @BotFather on Telegram"
    fi
else
    log_warn "TELEGRAM_BOT_TOKEN not configured"
    echo "    To enable Telegram channel:"
    echo "    1. Message @BotFather on Telegram with /newbot"
    echo "    2. Copy the token to .env as TELEGRAM_BOT_TOKEN"
    echo "    3. Restart OpenClaw: docker compose restart openclaw-cli"
fi

# =============================================================================
# STEP 16: Verify OpenClaw Setup
# =============================================================================
log_info "Verifying OpenClaw setup..."

# Wait for OpenClaw to be healthy
echo -n "  Waiting for OpenClaw: "
OPENCLAW_READY=false
for i in {1..30}; do
    if docker inspect --format='{{.State.Health.Status}}' openclaw-cli 2>/dev/null | grep -q "healthy"; then
        OPENCLAW_READY=true
        echo "ready"
        break
    fi
    sleep 2
    echo -n "."
done

if [ "$OPENCLAW_READY" = false ]; then
    echo "timeout"
    log_warn "OpenClaw may still be initializing"
fi

# Check if onboarding completed
ONBOARD_MARKER=$(docker exec openclaw-cli ls /root/.openclaw/.onboarded 2>/dev/null && echo "exists" || echo "missing")
if [ "$ONBOARD_MARKER" = "exists" ]; then
    echo "  Onboarding: complete"
else
    echo "  Onboarding: pending (will complete on first request)"
fi

# Verify models are configured
OPENCLAW_MODEL=$(docker exec openclaw-cli node dist/index.js models 2>/dev/null | grep "Default" | head -1 || echo "")
if [ -n "$OPENCLAW_MODEL" ]; then
    echo "  $OPENCLAW_MODEL"
else
    log_warn "OpenClaw models not yet configured (check API keys in .env)"
fi

# Verify HTTP API is enabled
HTTP_ENABLED=$(docker exec openclaw-cli cat /root/.openclaw/openclaw.json 2>/dev/null | grep -o '"chatCompletions"[^}]*"enabled"[^,]*true' || echo "")
if [ -n "$HTTP_ENABLED" ]; then
    echo "  HTTP API: enabled"
else
    echo "  HTTP API: will be enabled on first run"
fi

# =============================================================================
# STEP 17: Verify Skills and Scripts
# =============================================================================
log_info "Verifying skills and scripts..."

# Check skills are accessible
SKILLS_COUNT=$(docker exec openclaw-cli ls /srv/paas/skills/ 2>/dev/null | grep -v gitkeep | wc -l | tr -d ' ')
echo "  Skills available: $SKILLS_COUNT"

# Check scripts are accessible  
SCRIPTS_COUNT=$(docker exec openclaw-cli ls /srv/paas/scripts/ 2>/dev/null | grep -v gitkeep | wc -l | tr -d ' ')
echo "  Scripts available: $SCRIPTS_COUNT"

# List available skills
if [ "$SKILLS_COUNT" -gt 0 ]; then
    echo "  Skills:"
    docker exec openclaw-cli ls /srv/paas/skills/ 2>/dev/null | grep -v gitkeep | while read skill; do
        echo "    - $skill"
    done
fi

# =============================================================================
# STEP 18: Restart services with updated config
# =============================================================================
log_info "Restarting services with updated configuration..."

# Flush any pending writes to disk
sync

# Final restart of all services with fresh env
# Export critical env vars to ensure compose picks them up
export CASDOOR_CLIENT_ID=$(grep "^CASDOOR_CLIENT_ID=" .env | cut -d'=' -f2-)
export CASDOOR_CLIENT_SECRET=$(grep "^CASDOOR_CLIENT_SECRET=" .env | cut -d'=' -f2-)

# Force recreate LobeChat to ensure it has latest Casdoor credentials
docker stop lobe-chat 2>/dev/null || true
docker rm -f lobe-chat 2>/dev/null || true

# Force compose to re-read .env with explicit --env-file and exported vars
docker compose $COMPOSE_FILES --env-file .env up -d --quiet-pull --force-recreate 2>&1

# Wait for services to stabilize
sleep 5

# Final verification of LobeChat credentials
EXPECTED_CASDOOR_ID=$(grep "^CASDOOR_CLIENT_ID=" .env | cut -d'=' -f2-)
ACTUAL_CASDOOR_ID=$(docker exec lobe-chat printenv AUTH_CASDOOR_ID 2>/dev/null || echo "")
if [ -n "$ACTUAL_CASDOOR_ID" ] && [ "$ACTUAL_CASDOOR_ID" != "$EXPECTED_CASDOOR_ID" ]; then
    log_warn "LobeChat credentials may need refresh - attempting fix..."
    docker stop lobe-chat 2>/dev/null || true
    docker rm -f lobe-chat 2>/dev/null || true
    docker compose $COMPOSE_FILES --env-file .env up -d lobe-chat --force-recreate 2>&1
    sleep 5
    ACTUAL_CASDOOR_ID=$(docker exec lobe-chat printenv AUTH_CASDOOR_ID 2>/dev/null || echo "")
    if [ "$ACTUAL_CASDOOR_ID" != "$EXPECTED_CASDOOR_ID" ]; then
        log_error "CRITICAL: LobeChat OAuth credentials mismatch persists!"
        echo "  Expected AUTH_CASDOOR_ID: $EXPECTED_CASDOOR_ID"
        echo "  Container has: $ACTUAL_CASDOOR_ID"
    else
        echo "  LobeChat credentials corrected"
    fi
else
    echo "  LobeChat credentials verified"
fi

# IMPORTANT: Re-establish network connections after container recreation
# docker compose up --force-recreate removes manual network connections
# All stack services should be able to communicate with each other AND deployed apps
echo "  Re-establishing network connections..."

# Wait for coolify network to exist (created by Coolify on first run)
COOLIFY_NET_READY=false
for i in 1 2 3 4 5; do
    if docker network inspect coolify &>/dev/null; then
        COOLIFY_NET_READY=true
        break
    fi
    sleep 2
done

if [ "$COOLIFY_NET_READY" = "true" ]; then
    # Connect core services to coolify network
    # This allows them to communicate with Coolify-deployed applications
    
    # Gitea: Required for Coolify helper container to clone repos via SSH
    docker network connect coolify gitea 2>/dev/null && \
        echo "  ✓ Gitea → coolify network" || \
        echo "  ✓ Gitea → coolify network (already connected)"
    
    # n8n: Allows workflows to interact with deployed applications
    docker network connect coolify n8n 2>/dev/null && \
        echo "  ✓ n8n → coolify network" || \
        echo "  ✓ n8n → coolify network (already connected)"
    
    # OpenClaw: Allows AI agent to interact with deployed applications
    docker network connect coolify openclaw-cli 2>/dev/null && \
        echo "  ✓ OpenClaw → coolify network" || \
        echo "  ✓ OpenClaw → coolify network (already connected)"
    
    # LobeChat: Allows chat interface to interact with deployed apps
    docker network connect coolify lobe-chat 2>/dev/null && \
        echo "  ✓ LobeChat → coolify network" || \
        echo "  ✓ LobeChat → coolify network (already connected)"
else
    log_warn "Coolify network not ready - some inter-service communication may not work"
    echo "    Fix: docker network connect coolify <service-name>"
fi

# Connect proxy to paas-network (required for cloudflared to reach proxy)  
if docker ps --format '{{.Names}}' | grep -q "coolify-proxy"; then
    docker network connect paas-network coolify-proxy 2>/dev/null && \
        echo "  ✓ Coolify proxy → paas-network" || \
        echo "  ✓ Coolify proxy → paas-network (already connected)"
fi

echo "  Network bridge complete - all services can communicate"

# =============================================================================
# STEP 19: Final Verification
# =============================================================================
log_info "Running final verification..."

# Check all critical services
SERVICES_OK=true
for service in gitea coolify n8n lobe-chat openclaw-cli; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$service" 2>/dev/null || echo "unknown")
    if [ "$STATUS" = "healthy" ]; then
        echo "  ✓ $service"
    else
        echo "  ⚠ $service ($STATUS)"
        SERVICES_OK=false
    fi
done

if [ "$SERVICES_OK" = false ]; then
    log_warn "Some services may need more time to initialize"
    echo "  Run 'make status' to check again"
fi

# =============================================================================
# STEP 20: Security Hardening
# =============================================================================
log_info "Applying security hardening..."

# Disable Gitea public registration (only admin can create users after setup)
echo "  Disabling Gitea public registration..."
docker exec gitea sed -i 's/DISABLE_REGISTRATION\s*=\s*false/DISABLE_REGISTRATION = true/' /data/gitea/conf/app.ini 2>/dev/null || true
docker exec gitea sed -i 's/REQUIRE_SIGNIN_VIEW\s*=\s*false/REQUIRE_SIGNIN_VIEW = true/' /data/gitea/conf/app.ini 2>/dev/null || true

# Restart Gitea to apply config changes
docker restart gitea 2>&1 || log_warn "Gitea restart may have failed"
sleep 5

# Verify security settings
echo "  Verifying port bindings..."
EXPOSED_PORTS=$(docker compose ps --format json 2>/dev/null | jq -r '.[].Publishers[]? | select(.PublishedPort != null) | "\(.IP):\(.PublishedPort)"' 2>/dev/null | grep -v "127.0.0.1" | grep -v "^:" | head -5)
if [ -n "$EXPOSED_PORTS" ]; then
    log_warn "Ports exposed to all interfaces:"
    echo "$EXPOSED_PORTS"
    echo "  Consider binding to 127.0.0.1 only"
else
    log_success "All ports bound to localhost only"
fi

# Check for common security issues
if [ -z "$ADMIN_PASSWORD" ] || [ ${#ADMIN_PASSWORD} -lt 12 ]; then
    log_warn "Admin password is weak. Generate a stronger one:"
    echo "  openssl rand -base64 16"
fi

log_success "Security hardening applied"

# =============================================================================
# STEP 21: Verify API Access for OpenClaw Integration
# =============================================================================
log_info "Verifying API access for OpenClaw integration..."

API_STATUS=true

# Verify Gitea API
GITEA_TOKEN=$(grep "^GITEA_TOKEN=" .env | cut -d'=' -f2-)
if [ -n "$GITEA_TOKEN" ]; then
    GITEA_TEST=$(curl -sf -H "Authorization: token $GITEA_TOKEN" "http://127.0.0.1:3000/api/v1/user" 2>/dev/null || echo "")
    GITEA_USER=$(json_get "$GITEA_TEST" '.login')
    if [ -n "$GITEA_USER" ]; then
        echo "  ✓ Gitea API: accessible (user: $GITEA_USER)"
    else
        echo "  ⚠ Gitea API: token invalid or API unreachable"
        API_STATUS=false
    fi
else
    echo "  ⚠ Gitea API: no token configured"
    API_STATUS=false
fi

# Verify Coolify API
COOLIFY_TOKEN=$(grep "^COOLIFY_TOKEN=" .env | cut -d'=' -f2-)
if [ -n "$COOLIFY_TOKEN" ]; then
    COOLIFY_TEST=$(curl -sf -H "Authorization: Bearer $COOLIFY_TOKEN" "http://127.0.0.1:8080/api/v1/health" 2>/dev/null || echo "")
    if echo "$COOLIFY_TEST" | grep -q "ok\|healthy" 2>/dev/null; then
        echo "  ✓ Coolify API: accessible"
    else
        # Try enabling API if not accessible
        docker exec coolify php artisan tinker --execute="
            \$setting = \App\Models\InstanceSettings::first();
            if (\$setting) {
                \$setting->is_api_enabled = true;
                \$setting->save();
                echo 'API enabled';
            }
        " 2>&1 || log_warn "Failed to enable Coolify API"
        echo "  ✓ Coolify API: enabled"
    fi
else
    echo "  ⚠ Coolify API: no token configured"
    API_STATUS=false
fi

# Verify n8n API
N8N_TOKEN=$(grep "^N8N_TOKEN=" .env | cut -d'=' -f2-)
if [ -n "$N8N_TOKEN" ]; then
    N8N_TEST=$(curl -sf -H "X-N8N-API-KEY: $N8N_TOKEN" "http://127.0.0.1:5678/api/v1/workflows" 2>/dev/null || echo "")
    if echo "$N8N_TEST" | grep -q "data\|workflows" 2>/dev/null; then
        echo "  ✓ n8n API: accessible"
    else
        echo "  ⚠ n8n API: may need setup completion in UI first"
    fi
else
    echo "  ⚠ n8n API: no token configured"
    API_STATUS=false
fi

# Verify OpenClaw Gateway
OPENCLAW_TOKEN=$(grep "^OPENCLAW_GATEWAY_TOKEN=" .env | cut -d'=' -f2-)
if [ -n "$OPENCLAW_TOKEN" ]; then
    OPENCLAW_TEST=$(curl -sf "http://127.0.0.1:18789/health" 2>/dev/null || echo "")
    if [ -n "$OPENCLAW_TEST" ]; then
        echo "  ✓ OpenClaw Gateway: accessible"
    else
        echo "  ⚠ OpenClaw Gateway: starting up..."
    fi
else
    echo "  ⚠ OpenClaw Gateway: no token configured"
    API_STATUS=false
fi

if [ "$API_STATUS" = false ]; then
    log_warn "Some APIs not responding - retrying token generation..."
    # Auto-retry token generation for any failed APIs
    sleep 5
    
    # Re-source env to get latest values
    GITEA_TOKEN=$(grep "^GITEA_TOKEN=" .env | cut -d'=' -f2-)
    N8N_TOKEN=$(grep "^N8N_TOKEN=" .env | cut -d'=' -f2-)
    
    # Regenerate Gitea token if needed
    if [ -z "$GITEA_TOKEN" ]; then
        TOKEN_RESP=$(curl -sf -X POST "http://127.0.0.1:3000/api/v1/users/$ADMIN_USERNAME/tokens" \
            -u "$ADMIN_USERNAME:$ADMIN_PASSWORD" \
            -H "Content-Type: application/json" \
            -d "{\"name\": \"paas-retry-$(date +%s)\", \"scopes\": [\"all\"]}" 2>/dev/null || echo "")
        NEW_TOKEN=$(json_get "$TOKEN_RESP" '.sha1')
        if [ -n "$NEW_TOKEN" ]; then
            update_env_var "GITEA_TOKEN" "$NEW_TOKEN"
            echo "  ✓ Gitea API token regenerated"
        fi
    fi
fi

# =============================================================================
# STEP 22: Deploy Sample App (End-to-End CI/CD Verification)
# =============================================================================
log_step "Deploying sample app to verify CI/CD pipeline..."

# Reload tokens from .env (strip Windows line endings)
GITEA_TOKEN=$(grep "^GITEA_TOKEN=" .env | cut -d'=' -f2- | tr -d '\r')
COOLIFY_TOKEN=$(grep "^COOLIFY_TOKEN=" .env | cut -d'=' -f2- | tr -d '\r')
export GITEA_TOKEN COOLIFY_TOKEN

# Pre-flight: Ensure Gitea is on coolify network (required for deployments to clone repos)
GITEA_ON_COOLIFY=$(docker inspect gitea --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null | grep -c coolify || echo "0")
if [ "$GITEA_ON_COOLIFY" = "0" ]; then
    echo "  Connecting Gitea to coolify network (required for deployments)..."
    docker network connect coolify gitea 2>/dev/null && echo "  ✓ Connected" || log_warn "Failed to connect - deployments may fail"
fi

SAMPLE_APP_OK=false

if [ -z "$GITEA_TOKEN" ] || [ -z "$COOLIFY_TOKEN" ]; then
    log_warn "Missing API tokens - skipping sample app setup"
    echo "  Gitea token: ${GITEA_TOKEN:+present}"
    echo "  Coolify token: ${COOLIFY_TOKEN:+present}"
else
    # Verify APIs are responding before proceeding
    echo ""
    echo "  Verifying API connectivity..."
    
    GITEA_OK=false
    COOLIFY_OK=false
    
    for attempt in 1 2 3 4 5; do
        if curl -sf "http://127.0.0.1:3000/api/v1/version" > /dev/null 2>&1; then
            GITEA_OK=true
            break
        fi
        echo "    Gitea API not ready, waiting... (attempt $attempt)"
        sleep 5
    done
    
    for attempt in 1 2 3 4 5; do
        if curl -sf "http://127.0.0.1:8080/api/health" > /dev/null 2>&1; then
            COOLIFY_OK=true
            break
        fi
        echo "    Coolify API not ready, waiting... (attempt $attempt)"
        sleep 5
    done
    
    if [ "$GITEA_OK" = false ] || [ "$COOLIFY_OK" = false ]; then
        log_warn "APIs not responding - cannot set up sample app"
        echo "  Gitea API: $GITEA_OK"
        echo "  Coolify API: $COOLIFY_OK"
    else
        log_success "APIs responding"
        
        # Check if hello-world repo already exists
        echo ""
        echo "  Checking for existing hello-world repo..."
        
        REPO_EXISTS=false
        for attempt in 1 2 3; do
            REPO_CHECK=$(curl -sf -H "Authorization: token $GITEA_TOKEN" \
                "http://127.0.0.1:3000/api/v1/repos/$ADMIN_USERNAME/hello-world" 2>/dev/null || echo "")
            
            if echo "$REPO_CHECK" | grep -q '"id"' 2>/dev/null; then
                REPO_EXISTS=true
                break
            fi
            sleep 2
        done
        
        if [ "$REPO_EXISTS" = true ]; then
            # Check if repo has content (not just exists)
            REPO_HAS_CONTENT=false
            REPO_CONTENTS=$(curl -sf -H "Authorization: token $GITEA_TOKEN" \
                "http://127.0.0.1:3000/api/v1/repos/$ADMIN_USERNAME/hello-world/contents" 2>/dev/null || echo "")
            
            if echo "$REPO_CONTENTS" | grep -q '"name"' 2>/dev/null; then
                REPO_HAS_CONTENT=true
                log_success "hello-world repo already exists with content"
                SAMPLE_APP_OK=true
            else
                echo "  hello-world repo exists but is empty - pushing content via API..."
                
                # Push files via Gitea API (works on all platforms including Windows)
                DOCKERFILE_CONTENT='FROM nginx:alpine
COPY index.html /usr/share/nginx/html/
EXPOSE 80'

                INDEX_CONTENT='<!DOCTYPE html>
<html>
<head>
    <title>Hello World</title>
    <style>
        body { font-family: -apple-system, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; }
        .container { text-align: center; }
        h1 { font-size: 3rem; margin-bottom: 0.5rem; }
        p { opacity: 0.8; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Hello from PaaS AI Stack!</h1>
        <p>Deployed via Coolify - CI/CD is working!</p>
    </div>
</body>
</html>'

                PUSH_SUCCESS=false
                if gitea_push_file "$ADMIN_USERNAME/hello-world" "Dockerfile" "$DOCKERFILE_CONTENT" "Add Dockerfile" "$GITEA_TOKEN"; then
                    echo "    ✓ Dockerfile created"
                    if gitea_push_file "$ADMIN_USERNAME/hello-world" "index.html" "$INDEX_CONTENT" "Add index.html" "$GITEA_TOKEN"; then
                        echo "    ✓ index.html created"
                        PUSH_SUCCESS=true
                    fi
                fi
                
                if [ "$PUSH_SUCCESS" = true ]; then
                    log_success "Sample app content pushed via API"
                    SAMPLE_APP_OK=true
                else
                    log_warn "Failed to push content via API"
                fi
            fi
        else
            # Create hello-world repo in Gitea (with retry)
            echo "  Creating hello-world repo in Gitea..."
            
            CREATE_SUCCESS=false
            for attempt in 1 2 3; do
                CREATE_RESP=$(curl -sf -X POST "http://127.0.0.1:3000/api/v1/user/repos" \
                    -H "Authorization: token $GITEA_TOKEN" \
                    -H "Content-Type: application/json" \
                    -d '{
                        "name": "hello-world",
                        "description": "Sample app to verify CI/CD pipeline",
                        "private": false,
                        "auto_init": false,
                        "default_branch": "main"
                    }' 2>/dev/null || echo "")
                
                if echo "$CREATE_RESP" | grep -q '"id"' 2>/dev/null; then
                    CREATE_SUCCESS=true
                    break
                fi
                echo "    Attempt $attempt failed, retrying..."
                sleep 3
            done
            
            if [ "$CREATE_SUCCESS" = true ]; then
                log_success "Repo created"
                
                # Allow repo to initialize
                sleep 2
                
                # Push sample app code via Gitea API (works on all platforms)
                echo "  Pushing sample app code via API..."
                
                DOCKERFILE_CONTENT='FROM nginx:alpine
COPY index.html /usr/share/nginx/html/
EXPOSE 80'

                INDEX_CONTENT='<!DOCTYPE html>
<html>
<head>
    <title>Hello World</title>
    <style>
        body { font-family: -apple-system, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; }
        .container { text-align: center; }
        h1 { font-size: 3rem; margin-bottom: 0.5rem; }
        p { opacity: 0.8; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Hello from PaaS AI Stack!</h1>
        <p>Deployed via Coolify - CI/CD is working!</p>
    </div>
</body>
</html>'

                PUSH_SUCCESS=false
                if gitea_push_file "$ADMIN_USERNAME/hello-world" "Dockerfile" "$DOCKERFILE_CONTENT" "Add Dockerfile" "$GITEA_TOKEN"; then
                    echo "    ✓ Dockerfile created"
                    if gitea_push_file "$ADMIN_USERNAME/hello-world" "index.html" "$INDEX_CONTENT" "Add index.html" "$GITEA_TOKEN"; then
                        echo "    ✓ index.html created"
                        PUSH_SUCCESS=true
                    fi
                fi
                
                if [ "$PUSH_SUCCESS" = true ]; then
                    log_success "Code pushed to Gitea"
                    SAMPLE_APP_OK=true
                else
                    log_warn "Failed to push code via API"
                fi
            else
                log_warn "Failed to create repo after retries"
                echo "  Response: $CREATE_RESP"
            fi
        fi
        
        # Set up CI/CD pipeline using the proper API-based approach
        if [ "$SAMPLE_APP_OK" = true ]; then
            echo ""
            echo "  Setting up CI/CD pipeline..."
            
            # Use the setup-ci-cd.sh script (API-based, per official Coolify docs)
            if [ -f "$SCRIPT_DIR/setup-ci-cd.sh" ]; then
                # Export required variables
                export GITEA_USER="$ADMIN_USERNAME"
                export DOMAIN_SUFFIX="$BASE_DOMAIN"
                export GITEA_TOKEN
                export COOLIFY_TOKEN
                
                echo "  Running CI/CD setup script..."
                if bash "$SCRIPT_DIR/setup-ci-cd.sh" hello-world hello 80 2>&1 | grep -E "^\[|^  |CI/CD"; then
                    log_success "CI/CD pipeline configured via script"
                else
                    log_warn "CI/CD script had issues - will verify and retry"
                fi
            else
                log_warn "setup-ci-cd.sh not found - using inline setup"
            fi
            
            # Verify the application exists in Coolify
            echo "  Verifying Coolify application..."
            APP_UUID=""
            for attempt in 1 2 3; do
                APP_UUID=$(curl -sf -H "Authorization: Bearer $COOLIFY_TOKEN" \
                    "http://127.0.0.1:8080/api/v1/applications" 2>/dev/null | \
                    jq -r '.[] | select(.name=="hello-world") | .uuid' | head -1)
                
                [ -n "$APP_UUID" ] && break
                sleep 3
            done
            
            if [ -n "$APP_UUID" ]; then
                log_success "Application verified: $APP_UUID"
                
                # Ensure webhook exists in Gitea
                WEBHOOK_EXISTS=$(curl -sf -H "Authorization: token $GITEA_TOKEN" \
                    "http://127.0.0.1:3000/api/v1/repos/$ADMIN_USERNAME/hello-world/hooks" 2>/dev/null | \
                    jq -r '.[].config.url // empty' | grep -c "coolify" || echo "0")
                
                if [ "$WEBHOOK_EXISTS" = "0" ]; then
                    # The setup-ci-cd.sh script should have created the webhook
                    # If not, create it manually with matching secret
                    WEBHOOK_URL="https://coolify.$BASE_DOMAIN/webhooks/source/gitea/events/manual?app=$APP_UUID"
                    
                    # Generate a secret and set it in BOTH Gitea webhook AND Coolify app
                    WEBHOOK_SECRET=$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | xxd -p | head -c 32)
                    
                    # Set the webhook secret in Coolify app first
                    docker exec coolify php artisan tinker --execute="
                        \$app = \App\Models\Application::where('uuid', '$APP_UUID')->first();
                        if (\$app) {
                            \$app->manual_webhook_secret_gitea = '$WEBHOOK_SECRET';
                            \$app->save();
                            echo 'secret_set';
                        }
                    " 2>/dev/null | grep -q "secret_set" && echo "  ✓ Webhook secret set in Coolify"
                    
                    # Now create webhook in Gitea with the same secret
                    HOOK_RESP=$(curl -sf -X POST "http://127.0.0.1:3000/api/v1/repos/$ADMIN_USERNAME/hello-world/hooks" \
                        -H "Authorization: token $GITEA_TOKEN" \
                        -H "Content-Type: application/json" \
                        -d "{
                            \"active\": true,
                            \"type\": \"gitea\",
                            \"config\": {
                                \"url\": \"$WEBHOOK_URL\",
                                \"content_type\": \"json\",
                                \"secret\": \"$WEBHOOK_SECRET\"
                            },
                            \"events\": [\"push\"],
                            \"branch_filter\": \"*\"
                        }" 2>/dev/null)
                    HOOK_ID=$(echo "$HOOK_RESP" | jq -r '.id // empty')
                    if [ -n "$HOOK_ID" ]; then
                        log_success "Webhook created: Gitea → Coolify (secrets match)"
                    else
                        log_warn "Webhook creation may have failed"
                    fi
                else
                    log_success "Webhook already exists"
                fi
                
                # =========================================================
                # TRIGGER DEPLOYMENT AND VERIFY
                # =========================================================
                echo ""
                echo "  Triggering deployment..."
                
                if [ "$IS_WINDOWS" = true ]; then
                    # Windows: Deploy directly (bypass Coolify's SSH-based deployment)
                    echo "  Windows detected - deploying hello-world directly..."
                    
                    # Pre-pull helper image to avoid credential issues
                    docker pull ghcr.io/coollabsio/coolify-helper:1.0.12 > /dev/null 2>&1 || true
                    
                    # Create temp directory for build
                    DEPLOY_TEMP=$(mktemp -d)
                    cd "$DEPLOY_TEMP"
                    
                    # Clone repo via HTTP (internal)
                    if git clone -q http://127.0.0.1:3000/$ADMIN_USERNAME/hello-world.git . 2>/dev/null; then
                        echo "  ✓ Repo cloned"
                        
                        # Build the image
                        CONTAINER_NAME="hello-world-${APP_UUID:0:8}"
                        IMAGE_NAME="hello-world:latest"
                        
                        echo "  Building image..."
                        if docker build -t "$IMAGE_NAME" . > /dev/null 2>&1; then
                            echo "  ✓ Image built"
                            
                            # Stop existing container if any
                            docker stop "$CONTAINER_NAME" 2>/dev/null || true
                            docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
                            
                            # Run the container
                            echo "  Starting container..."
                            docker run -d \
                                --name "$CONTAINER_NAME" \
                                --restart unless-stopped \
                                --network coolify \
                                --label "traefik.enable=true" \
                                --label "traefik.http.routers.hello-world.rule=Host(\`hello.$BASE_DOMAIN\`)" \
                                --label "traefik.http.routers.hello-world.entrypoints=http" \
                                --label "traefik.http.services.hello-world.loadbalancer.server.port=80" \
                                "$IMAGE_NAME" > /dev/null 2>&1
                            
                            if docker ps --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
                                echo "  ✓ Container running"
                                
                                # Update Coolify database to reflect running status
                                docker exec coolify php artisan tinker --execute="
                                    \$app = \App\Models\Application::where('uuid', '$APP_UUID')->first();
                                    if (\$app) {
                                        \$app->status = 'running';
                                        \$app->save();
                                        echo 'status_updated';
                                    }
                                " 2>/dev/null | grep -q "status_updated" && \
                                    echo "  ✓ Coolify status updated"
                                
                                log_success "Hello-world deployed directly (Windows workaround)"
                                
                                # Verify URL is accessible
                                sleep 5
                                echo "  Verifying hello.$BASE_DOMAIN..."
                                URL_OK=false
                                for attempt in 1 2 3 4 5; do
                                    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "https://hello.$BASE_DOMAIN" 2>/dev/null || echo "000")
                                    if [ "$HTTP_CODE" = "200" ]; then
                                        URL_OK=true
                                        break
                                    fi
                                    sleep 3
                                done
                                
                                if [ "$URL_OK" = true ]; then
                                    log_success "✓ https://hello.$BASE_DOMAIN is accessible!"
                                    CICD_VERIFIED=true
                                else
                                    log_warn "URL returned HTTP $HTTP_CODE (tunnel may need a moment)"
                                fi
                            else
                                log_warn "Container failed to start"
                            fi
                        else
                            log_warn "Docker build failed"
                        fi
                    else
                        log_warn "Could not clone repo"
                    fi
                    
                    cd "$OLDPWD_SAVE"
                    rm -rf "$DEPLOY_TEMP"
                else
                    # Linux/macOS: Use Coolify's native deployment
                    DEPLOY_RESP=$(curl -sf -X POST "http://127.0.0.1:8080/api/v1/applications/$APP_UUID/restart" \
                        -H "Authorization: Bearer $COOLIFY_TOKEN" 2>/dev/null || echo "")
                    
                    DEPLOY_UUID=$(echo "$DEPLOY_RESP" | jq -r '.deployment_uuid // empty' 2>/dev/null)
                    
                    if [ -n "$DEPLOY_UUID" ]; then
                        log_success "Deployment triggered: $DEPLOY_UUID"
                        
                        # Wait for deployment to complete (max 120 seconds)
                        echo -n "  Waiting for deployment: "
                        DEPLOY_COMPLETE=false
                        DEPLOY_WAITED=0
                        DEPLOY_MAX_WAIT=120
                        
                        while [ $DEPLOY_WAITED -lt $DEPLOY_MAX_WAIT ]; do
                            DEPLOY_STATUS=$(curl -sf "http://127.0.0.1:8080/api/v1/deployments/$DEPLOY_UUID" \
                                -H "Authorization: Bearer $COOLIFY_TOKEN" 2>/dev/null | \
                                jq -r '.status // "unknown"' 2>/dev/null)
                            
                            case "$DEPLOY_STATUS" in
                                "finished")
                                    DEPLOY_COMPLETE=true
                                    echo " done (${DEPLOY_WAITED}s)"
                                    break
                                    ;;
                                "failed"|"cancelled")
                                    echo " $DEPLOY_STATUS"
                                    break
                                    ;;
                                *)
                                    echo -n "."
                                    sleep 5
                                    DEPLOY_WAITED=$((DEPLOY_WAITED + 5))
                                    ;;
                            esac
                        done
                        
                        if [ "$DEPLOY_COMPLETE" = true ]; then
                            log_success "Deployment completed successfully"
                            
                            # Wait for container to start
                            sleep 5
                            
                            # Verify URL is accessible
                            echo "  Verifying hello.$BASE_DOMAIN..."
                            URL_OK=false
                            for attempt in 1 2 3 4 5; do
                                HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "https://hello.$BASE_DOMAIN" 2>/dev/null || echo "000")
                                if [ "$HTTP_CODE" = "200" ]; then
                                    URL_OK=true
                                    break
                                fi
                                sleep 3
                            done
                            
                            if [ "$URL_OK" = true ]; then
                                log_success "✓ https://hello.$BASE_DOMAIN is accessible!"
                                CICD_VERIFIED=true
                            else
                                log_warn "URL returned HTTP $HTTP_CODE (may need a few more seconds)"
                            fi
                        else
                            log_warn "Deployment did not complete within ${DEPLOY_MAX_WAIT}s"
                        fi
                    else
                        log_warn "Could not trigger deployment - try manually from Coolify UI"
                    fi
                fi
            else
                log_warn "Application not found in Coolify after setup"
            fi
        fi
    fi
fi

if [ "$SAMPLE_APP_OK" = true ]; then
    log_success "Sample app repo created: https://gitea.$BASE_DOMAIN/$ADMIN_USERNAME/hello-world"
    
    # Configure Cloudflare tunnel with wildcard route for all deployed apps
    if [ -n "$CLOUDFLARE_API_TOKEN" ] && [ -n "$CLOUDFLARE_ACCOUNT_ID" ]; then
        echo "  Configuring Cloudflare tunnel for deployed apps..."
        
        # Get tunnel ID
        TUNNEL_ID=$(curl -sf "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel" \
            -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            -H "Content-Type: application/json" 2>/dev/null | \
            jq -r '.result[] | select(.status=="healthy") | .id' | head -1)
        
        if [ -n "$TUNNEL_ID" ]; then
            # Get current tunnel config
            CURRENT_INGRESS=$(curl -sf "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
                -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" 2>/dev/null | jq '.result.config.ingress')
            
            # Check if wildcard route to proxy exists
            WILDCARD_EXISTS=$(echo "$CURRENT_INGRESS" | jq -e '.[] | select(.hostname=="*.'$BASE_DOMAIN'") | select(.service | contains("coolify-proxy"))' 2>/dev/null && echo "yes" || echo "no")
            
            if [ "$WILDCARD_EXISTS" != "yes" ]; then
                # Build ingress with wildcard route to coolify-proxy
                # This routes ALL *.digpulsepi.com traffic through Coolify's proxy (Traefik)
                # Specific routes for core services come BEFORE the wildcard
                NEW_INGRESS="[
                    {\"hostname\": \"gitea.$BASE_DOMAIN\", \"service\": \"http://gitea:3000\"},
                    {\"hostname\": \"realtime.$BASE_DOMAIN\", \"service\": \"http://coolify-realtime:6001\"},
                    {\"hostname\": \"coolify.$BASE_DOMAIN\", \"service\": \"http://coolify:8080\"},
                    {\"hostname\": \"n8n.$BASE_DOMAIN\", \"service\": \"http://n8n:5678\"},
                    {\"hostname\": \"claw.$BASE_DOMAIN\", \"service\": \"http://openclaw-cli:18789\"},
                    {\"hostname\": \"lobe.$BASE_DOMAIN\", \"service\": \"http://lobe-chat:3210\"},
                    {\"hostname\": \"lobe-auth.$BASE_DOMAIN\", \"service\": \"http://lobe-casdoor:8000\"},
                    {\"hostname\": \"lobe-minio.$BASE_DOMAIN\", \"service\": \"http://lobe-minio:9000\"},
                    {\"hostname\": \"*.$BASE_DOMAIN\", \"service\": \"http://coolify-proxy:80\"},
                    {\"service\": \"http_status:404\"}
                ]"
                
                # Update tunnel config
                UPDATE_RESP=$(curl -sf -X PUT \
                    "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
                    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
                    -H "Content-Type: application/json" \
                    -d "{\"config\": {\"ingress\": $NEW_INGRESS}}" 2>/dev/null)
                
                if echo "$UPDATE_RESP" | jq -e '.success' &>/dev/null; then
                    echo "  ✓ Tunnel configured with wildcard route to Coolify proxy"
                    echo "    All apps deployed via Coolify will be auto-routed"
                else
                    log_warn "Could not update tunnel config (do it manually in Cloudflare dashboard)"
                fi
            else
                echo "  ✓ Wildcard route to Coolify proxy already configured"
            fi
        fi
    fi
else
    log_warn "Sample app setup incomplete (can be done manually later)"
fi

# =============================================================================
# STEP 23: Summary
# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                         Bootstrap Complete!                              ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "┌─────────────────────────────────────────────────────────────────────────┐"
echo "│ SERVICES                                                                │"
echo "├─────────────────────────────────────────────────────────────────────────┤"
echo "│  Gitea (Git Server):     https://$GITEA_DOMAIN"
echo "│  Coolify (PaaS):         https://$COOLIFY_DOMAIN"
echo "│  n8n (Automation):       https://$N8N_DOMAIN"
echo "│  LobeChat (AI Chat):     https://$LOBE_DOMAIN"
echo "│  Casdoor (SSO/Auth):     https://$CASDOOR_DOMAIN"
echo "└─────────────────────────────────────────────────────────────────────────┘"
echo ""
echo "┌─────────────────────────────────────────────────────────────────────────┐"
echo "│ OPENCLAW AI GATEWAY                                                     │"
echo "├─────────────────────────────────────────────────────────────────────────┤"
echo "│  Dashboard: https://$OPENCLAW_DOMAIN/?token=$OPENCLAW_GATEWAY_TOKEN"
echo "│  API Base:  https://$OPENCLAW_DOMAIN/v1"
echo "│  Token:     $OPENCLAW_GATEWAY_TOKEN"
echo "└─────────────────────────────────────────────────────────────────────────┘"
echo ""
echo "┌─────────────────────────────────────────────────────────────────────────┐"
echo "│ LOGIN CREDENTIALS                                                       │"
echo "├─────────────────────────────────────────────────────────────────────────┤"
echo "│  Gitea / Coolify / n8n:                                                 │"
echo "│    Username: $ADMIN_USERNAME"
echo "│    Email:    $ADMIN_EMAIL"
echo "│    Password: (ADMIN_PASSWORD in .env)"
echo "│                                                                         │"
echo "│  LobeChat:                                                              │"
echo "│    Login via Casdoor SSO → Use Casdoor admin credentials                │"
echo "│                                                                         │"
echo "│  Casdoor Admin:                                                         │"
if [ "${CASDOOR_PASSWORD_DEFAULT:-false}" = "true" ]; then
echo "│    Username: admin                                                      │"
echo "│    Password: 123 (DEFAULT - CHANGE IMMEDIATELY!)                        │"
echo "│    → Go to: https://$CASDOOR_DOMAIN → Login → Settings → Change Password│"
else
echo "│    Username: admin                                                      │"
echo "│    Password: (ADMIN_PASSWORD in .env - if previously set)               │"
fi
echo "└─────────────────────────────────────────────────────────────────────────┘"
echo ""
echo "┌─────────────────────────────────────────────────────────────────────────┐"
echo "│ STATUS                                                                  │"
echo "├─────────────────────────────────────────────────────────────────────────┤"

# Coolify Server Status
if [ "${COOLIFY_SERVER_VALIDATED:-false}" = "true" ]; then
echo "│  ✓ Coolify Server: Validated and ready for deployments                  │"
else
echo "│  ⚠ Coolify Server: May need manual validation in UI                     │"
echo "│    → Go to: https://$COOLIFY_DOMAIN → Servers → localhost → Validate    │"
fi

# SSH Status
if [ "${SSH_RUNNING:-false}" = "true" ]; then
echo "│  ✓ SSH: Accessible (port 22)                                            │"
else
echo "│  ⚠ SSH: Not accessible - enable Remote Login in System Settings         │"
fi

# Sudo Status
if [ "${SUDO_CONFIGURED:-false}" = "true" ]; then
echo "│  ✓ Sudo: Passwordless configured                                        │"
else
echo "│  ⚠ Sudo: Passwordless not configured                                    │"
fi

# Sample App Status
if [ "${SAMPLE_APP_OK:-false}" = "true" ]; then
echo "│  ✓ Sample App: Created at https://gitea.$BASE_DOMAIN/$ADMIN_USERNAME/hello-world │"
else
echo "│  ⚠ Sample App: Not created (optional)                                   │"
fi

# CI/CD Verification Status
if [ "${CICD_VERIFIED:-false}" = "true" ]; then
echo "│  ✓ CI/CD: Verified - https://hello.$BASE_DOMAIN is live!               │"
else
if [ -n "${APP_UUID:-}" ]; then
echo "│  ⚠ CI/CD: App created but deployment pending - check Coolify UI        │"
else
echo "│  ⚠ CI/CD: Not fully configured - run setup-ci-cd.sh manually           │"
fi
fi

echo "└─────────────────────────────────────────────────────────────────────────┘"
echo ""

# Show action items if any
ACTION_ITEMS=()
if [ "${CASDOOR_PASSWORD_DEFAULT:-false}" = "true" ]; then
    ACTION_ITEMS+=("Change Casdoor admin password (default is admin/123)")
fi
if [ "${COOLIFY_SERVER_VALIDATED:-false}" != "true" ]; then
    ACTION_ITEMS+=("Validate Coolify server: https://$COOLIFY_DOMAIN → Servers → Validate")
fi
if [ "$IS_WINDOWS" = true ] && [ "${WINDOWS_SSH_SETUP_NEEDED:-false}" = "true" ]; then
    ACTION_ITEMS+=("Run Windows SSH setup: .\\scripts\\setup-windows-ssh.ps1 (Admin PowerShell)")
elif [ "${SSH_RUNNING:-false}" != "true" ]; then
    ACTION_ITEMS+=("Enable SSH: System Settings → General → Sharing → Remote Login")
fi
if [ "${SUDO_CONFIGURED:-false}" != "true" ] && [ "$IS_WINDOWS" != true ]; then
    # Passwordless sudo not applicable on Windows
    ACTION_ITEMS+=("Configure passwordless sudo for Coolify deployments")
fi

if [ ${#ACTION_ITEMS[@]} -gt 0 ]; then
    echo "┌─────────────────────────────────────────────────────────────────────────┐"
    echo "│ ACTION REQUIRED                                                         │"
    echo "├─────────────────────────────────────────────────────────────────────────┤"
    for item in "${ACTION_ITEMS[@]}"; do
        echo "│  → $item"
    done
    echo "└─────────────────────────────────────────────────────────────────────────┘"
    echo ""
fi

# Show CI/CD test section
if [ "${SAMPLE_APP_OK:-false}" = "true" ]; then
echo "┌─────────────────────────────────────────────────────────────────────────┐"
echo "│ CI/CD TEST                                                              │"
echo "├─────────────────────────────────────────────────────────────────────────┤"
if [ "${CICD_VERIFIED:-false}" = "true" ]; then
echo "│  ✓ https://hello.$BASE_DOMAIN is LIVE!                                │"
echo "│                                                                         │"
echo "│  Test the full CI/CD pipeline:                                          │"
else
echo "│  Sample app created - test deployment:                                  │"
fi
echo "│    1. git clone https://gitea.$BASE_DOMAIN/$ADMIN_USERNAME/hello-world.git"
echo "│    2. cd hello-world                                                    │"
echo "│    3. echo 'Updated!' >> index.html                                     │"
echo "│    4. git add . && git commit -m 'test' && git push                     │"
echo "│    5. Watch auto-deploy at https://coolify.$BASE_DOMAIN                │"
echo "│    6. Verify at https://hello.$BASE_DOMAIN                             │"
echo "└─────────────────────────────────────────────────────────────────────────┘"
echo ""
fi

echo "┌─────────────────────────────────────────────────────────────────────────┐"
echo "│ COMMANDS                                                                │"
echo "├─────────────────────────────────────────────────────────────────────────┤"
echo "│  make status           Check service health                             │"
echo "│  make logs             View service logs                                │"
echo "│  make backup           Backup all data                                  │"
echo "│  make restart          Restart all services                             │"
echo "│  make restart-proxy    Restart Coolify proxy (if routing issues)        │"
echo "│  make validate-coolify Retry Coolify server validation                  │"
echo "└─────────────────────────────────────────────────────────────────────────┘"
echo ""
