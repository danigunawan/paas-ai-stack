#!/bin/bash
# =============================================================================
# CI/CD Setup Script (API-based)
# =============================================================================
# Creates a complete CI/CD pipeline using Gitea and Coolify APIs:
#   1. Creates/verifies repository in Gitea
#   2. Generates SSH deploy key pair
#   3. Adds private key to Coolify via API
#   4. Adds public key to Gitea repo via API
#   5. Creates application in Coolify with deploy key
#   6. Creates webhook in Gitea with secret
#
# Usage: ./setup-ci-cd.sh <repo-name> <subdomain> [port]
#
# Example: ./setup-ci-cd.sh my-app myapp 3000
#          Creates app at https://myapp.digpulsepi.com
#
# Requirements:
#   - GITEA_TOKEN env var (Gitea API token)
#   - COOLIFY_TOKEN env var (Coolify API token)
#   - ssh-keygen available
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration - detect if running locally or inside container
if [ -f "/.dockerenv" ]; then
    # Inside container - use internal URLs
    GITEA_URL="${GITEA_URL:-http://gitea:3000}"
    COOLIFY_URL="${COOLIFY_URL:-http://coolify:8080}"
    GITEA_SSH_HOST="gitea"
else
    # Outside container - use localhost/external URLs
    GITEA_URL="${GITEA_URL:-http://127.0.0.1:3000}"
    COOLIFY_URL="${COOLIFY_URL:-http://127.0.0.1:8080}"
    GITEA_SSH_HOST="gitea"  # Internal SSH host for Coolify
fi

GITEA_EXTERNAL_URL="${GITEA_EXTERNAL_URL:-https://gitea.digpulsepi.com}"
GITEA_USER="${GITEA_USER:-bullish0x}"
DOMAIN_SUFFIX="${DOMAIN_SUFFIX:-digpulsepi.com}"
KEY_DIR="${KEY_DIR:-$(dirname "$0")/../data/deploy-keys}"

# Arguments
REPO_NAME="${1:-}"
SUBDOMAIN="${2:-}"
PORT="${3:-80}"

usage() {
    echo "Usage: $0 <repo-name> <subdomain> [port]"
    echo ""
    echo "Arguments:"
    echo "  repo-name   Name of the repository in Gitea"
    echo "  subdomain   Subdomain for the app (e.g., 'myapp' → myapp.$DOMAIN_SUFFIX)"
    echo "  port        Port the app listens on (default: 80)"
    echo ""
    echo "Environment variables:"
    echo "  GITEA_TOKEN    Gitea API token (required)"
    echo "  COOLIFY_TOKEN  Coolify API token (required)"
    echo "  GITEA_USER     Gitea username (default: bullish0x)"
    echo "  DOMAIN_SUFFIX  Domain suffix (default: digpulsepi.com)"
    echo ""
    echo "Example:"
    echo "  $0 my-api api 8080"
    exit 1
}

log() { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[→]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# Validate arguments
[ -z "$REPO_NAME" ] && usage
[ -z "$SUBDOMAIN" ] && usage

# Load tokens from .env if not set (handles Windows line endings)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

if [ -z "$GITEA_TOKEN" ] && [ -f "$ENV_FILE" ]; then
    GITEA_TOKEN=$(grep "^GITEA_TOKEN=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '\r\n')
    export GITEA_TOKEN
fi

if [ -z "$COOLIFY_TOKEN" ] && [ -f "$ENV_FILE" ]; then
    COOLIFY_TOKEN=$(grep "^COOLIFY_TOKEN=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '\r\n')
    export COOLIFY_TOKEN
fi

# Strip any carriage returns from tokens (Windows compatibility)
GITEA_TOKEN=$(echo "$GITEA_TOKEN" | tr -d '\r')
COOLIFY_TOKEN=$(echo "$COOLIFY_TOKEN" | tr -d '\r')

# Validate environment
[ -z "$GITEA_TOKEN" ] && error "GITEA_TOKEN environment variable is required"
[ -z "$COOLIFY_TOKEN" ] && error "COOLIFY_TOKEN environment variable is required"

FULL_DOMAIN="$SUBDOMAIN.$DOMAIN_SUFFIX"
KEY_NAME="${REPO_NAME}-deploy-key"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              CI/CD Pipeline Setup (API-based)                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Repository:  $GITEA_USER/$REPO_NAME"
echo "  Domain:      https://$FULL_DOMAIN"
echo "  Port:        $PORT"
echo ""

# =============================================================================
# Step 1: Verify/Create Repository in Gitea
# =============================================================================
info "Checking repository in Gitea..."

REPO_CHECK=$(curl -s -o /dev/null -w "%{http_code}" "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME" \
    -H "Authorization: token $GITEA_TOKEN")

if [ "$REPO_CHECK" = "200" ]; then
    log "Repository exists: $GITEA_USER/$REPO_NAME"
elif [ "$REPO_CHECK" = "404" ]; then
    info "Creating repository..."
    CREATE_RESP=$(curl -sf -X POST "$GITEA_URL/api/v1/user/repos" \
        -H "Authorization: token $GITEA_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$REPO_NAME\",
            \"description\": \"Deployed via PaaS AI Stack\",
            \"private\": false,
            \"default_branch\": \"main\"
        }" 2>&1) || error "Failed to create repository: $CREATE_RESP"
    log "Repository created: $GITEA_USER/$REPO_NAME"
else
    error "Cannot access Gitea API (HTTP $REPO_CHECK)"
fi

# =============================================================================
# Step 2: Generate SSH Deploy Key Pair
# =============================================================================
info "Setting up deploy key..."

mkdir -p "$KEY_DIR"
KEY_PATH="$KEY_DIR/$KEY_NAME"

if [ -f "$KEY_PATH" ]; then
    log "Deploy key already exists: $KEY_PATH"
else
    info "Generating new SSH key pair..."
    ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "$KEY_NAME" >/dev/null 2>&1
    log "Deploy key generated: $KEY_PATH"
fi

PRIVATE_KEY=$(cat "$KEY_PATH")
PUBLIC_KEY=$(cat "${KEY_PATH}.pub")

# =============================================================================
# Step 3: Add Private Key to Coolify via API
# =============================================================================
info "Adding private key to Coolify..."

# Check if key already exists
EXISTING_KEY=$(curl -sf "$COOLIFY_URL/api/v1/security/keys" \
    -H "Authorization: Bearer $COOLIFY_TOKEN" 2>/dev/null | \
    jq -r ".[] | select(.name == \"$KEY_NAME\") | .uuid" 2>/dev/null || echo "")

if [ -n "$EXISTING_KEY" ] && [ "$EXISTING_KEY" != "null" ]; then
    KEY_UUID="$EXISTING_KEY"
    log "Private key exists in Coolify: $KEY_UUID"
else
    # Escape the private key for JSON
    ESCAPED_KEY=$(printf '%s' "$PRIVATE_KEY" | jq -Rs .)
    
    KEY_RESP=$(curl -sf -X POST "$COOLIFY_URL/api/v1/security/keys" \
        -H "Authorization: Bearer $COOLIFY_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$KEY_NAME\",
            \"description\": \"Deploy key for $REPO_NAME\",
            \"private_key\": $ESCAPED_KEY
        }" 2>&1) || error "Failed to create key in Coolify: $KEY_RESP"
    
    KEY_UUID=$(echo "$KEY_RESP" | jq -r '.uuid // empty')
    [ -z "$KEY_UUID" ] && error "Failed to get key UUID from Coolify response"
    log "Private key added to Coolify: $KEY_UUID"
fi

# =============================================================================
# Step 4: Add Public Key to Gitea Repository
# =============================================================================
info "Adding deploy key to Gitea repository..."

# Check if deploy key already exists
EXISTING_DEPLOY_KEY=$(curl -sf "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/keys" \
    -H "Authorization: token $GITEA_TOKEN" 2>/dev/null | \
    jq -r ".[] | select(.title == \"$KEY_NAME\") | .id" 2>/dev/null || echo "")

if [ -n "$EXISTING_DEPLOY_KEY" ] && [ "$EXISTING_DEPLOY_KEY" != "null" ]; then
    log "Deploy key exists in Gitea: ID $EXISTING_DEPLOY_KEY"
else
    DEPLOY_KEY_RESP=$(curl -sf -X POST "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/keys" \
        -H "Authorization: token $GITEA_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"title\": \"$KEY_NAME\",
            \"key\": \"$PUBLIC_KEY\",
            \"read_only\": true
        }" 2>&1) || error "Failed to add deploy key to Gitea: $DEPLOY_KEY_RESP"
    
    DEPLOY_KEY_ID=$(echo "$DEPLOY_KEY_RESP" | jq -r '.id // empty')
    log "Deploy key added to Gitea: ID $DEPLOY_KEY_ID"
fi

# =============================================================================
# Step 5: Get Coolify Server and Project UUIDs
# =============================================================================
info "Fetching Coolify configuration..."

# Get server UUID
SERVER_UUID=$(curl -sf "$COOLIFY_URL/api/v1/servers" \
    -H "Authorization: Bearer $COOLIFY_TOKEN" 2>/dev/null | \
    jq -r '.[0].uuid // empty')
[ -z "$SERVER_UUID" ] && error "No servers found in Coolify"
log "Server UUID: $SERVER_UUID"

# Get or create project
PROJECT_UUID=$(curl -sf "$COOLIFY_URL/api/v1/projects" \
    -H "Authorization: Bearer $COOLIFY_TOKEN" 2>/dev/null | \
    jq -r '.[0].uuid // empty')

if [ -z "$PROJECT_UUID" ]; then
    info "Creating default project..."
    PROJECT_RESP=$(curl -sf -X POST "$COOLIFY_URL/api/v1/projects" \
        -H "Authorization: Bearer $COOLIFY_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"name": "Default", "description": "Default project"}' 2>&1)
    PROJECT_UUID=$(echo "$PROJECT_RESP" | jq -r '.uuid // empty')
fi
[ -z "$PROJECT_UUID" ] && error "No project found and failed to create one"
log "Project UUID: $PROJECT_UUID"

# =============================================================================
# Step 6: Check for Existing Application
# =============================================================================
info "Checking for existing application..."

EXISTING_APP=$(curl -sf "$COOLIFY_URL/api/v1/applications" \
    -H "Authorization: Bearer $COOLIFY_TOKEN" 2>/dev/null | \
    jq -r ".[] | select(.name == \"$REPO_NAME\") | .uuid" 2>/dev/null || echo "")

# =============================================================================
# Step 7: Create Application with Deploy Key (or update existing)
# =============================================================================
# Git SSH URL using internal hostname
GIT_SSH_URL="git@${GITEA_SSH_HOST}:${GITEA_USER}/${REPO_NAME}.git"

# Generate webhook secret
WEBHOOK_SECRET=$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | xxd -p | head -c 32)

if [ -n "$EXISTING_APP" ] && [ "$EXISTING_APP" != "null" ]; then
    APP_UUID="$EXISTING_APP"
    warn "Application already exists: $APP_UUID"
    info "Updating application configuration..."
    
    # Update via API (PATCH not supported for all fields, so we use the database)
    docker exec coolify php artisan tinker --execute="
        \$app = \App\Models\Application::where('uuid', '$APP_UUID')->first();
        if (\$app) {
            \$key = \App\Models\PrivateKey::where('uuid', '$KEY_UUID')->first();
            \$app->git_repository = '$GIT_SSH_URL';
            \$app->git_branch = 'main';
            \$app->private_key_id = \$key ? \$key->id : null;
            \$app->manual_webhook_secret_gitea = '$WEBHOOK_SECRET';
            \$app->fqdn = 'http://$FULL_DOMAIN';
            \$app->ports_exposes = '$PORT';
            \$app->custom_labels = null;
            \$app->save();
            echo 'updated';
        }
    " 2>/dev/null | grep -q "updated" && log "Application updated with deploy key"
else
    info "Creating application in Coolify..."
    
    APP_RESP=$(curl -sf -X POST "$COOLIFY_URL/api/v1/applications/private-deploy-key" \
        -H "Authorization: Bearer $COOLIFY_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"project_uuid\": \"$PROJECT_UUID\",
            \"server_uuid\": \"$SERVER_UUID\",
            \"environment_name\": \"production\",
            \"private_key_uuid\": \"$KEY_UUID\",
            \"git_repository\": \"$GIT_SSH_URL\",
            \"git_branch\": \"main\",
            \"name\": \"$REPO_NAME\",
            \"description\": \"Deployed from Gitea via PaaS AI Stack\",
            \"domains\": \"http://$FULL_DOMAIN\",
            \"ports_exposes\": \"$PORT\",
            \"build_pack\": \"dockerfile\",
            \"is_auto_deploy_enabled\": true,
            \"is_force_https_enabled\": false,
            \"manual_webhook_secret_gitea\": \"$WEBHOOK_SECRET\",
            \"instant_deploy\": false
        }" 2>&1)
    
    APP_UUID=$(echo "$APP_RESP" | jq -r '.uuid // empty')
    
    if [ -z "$APP_UUID" ]; then
        echo "API Response: $APP_RESP"
        error "Failed to create application"
    fi
    log "Application created: $APP_UUID"
fi

# =============================================================================
# Step 8: Create Webhook in Gitea
# =============================================================================
info "Setting up webhook in Gitea..."

WEBHOOK_URL="https://coolify.$DOMAIN_SUFFIX/webhooks/source/gitea/events/manual?app=$APP_UUID"

# Delete existing webhooks for this app
EXISTING_HOOKS=$(curl -sf "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks" \
    -H "Authorization: token $GITEA_TOKEN" 2>/dev/null | \
    jq -r ".[] | select(.config.url | contains(\"$APP_UUID\")) | .id" 2>/dev/null || echo "")

for HOOK_ID in $EXISTING_HOOKS; do
    if [ -n "$HOOK_ID" ] && [ "$HOOK_ID" != "null" ]; then
        curl -sf -X DELETE "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks/$HOOK_ID" \
            -H "Authorization: token $GITEA_TOKEN" 2>/dev/null
        info "Removed old webhook: $HOOK_ID"
    fi
done

# Create new webhook
WEBHOOK_RESP=$(curl -sf -X POST "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks" \
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
        \"events\": [\"push\", \"pull_request\"],
        \"branch_filter\": \"*\"
    }" 2>&1)

WEBHOOK_ID=$(echo "$WEBHOOK_RESP" | jq -r '.id // empty')
if [ -n "$WEBHOOK_ID" ] && [ "$WEBHOOK_ID" != "null" ]; then
    log "Webhook created: ID $WEBHOOK_ID"
else
    warn "Webhook creation may have failed: $WEBHOOK_RESP"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    CI/CD Setup Complete                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Application"
echo "  ─────────────────────────────────────────────────────────────"
echo "  URL:           https://$FULL_DOMAIN"
echo "  Coolify UUID:  $APP_UUID"
echo "  Git SSH URL:   $GIT_SSH_URL"
echo ""
echo "  Deploy Key"
echo "  ─────────────────────────────────────────────────────────────"
echo "  Name:          $KEY_NAME"
echo "  Coolify UUID:  $KEY_UUID"
echo "  Key File:      $KEY_PATH"
echo ""
echo "  Webhook"
echo "  ─────────────────────────────────────────────────────────────"
echo "  URL:           $WEBHOOK_URL"
echo "  Secret:        $WEBHOOK_SECRET"
echo ""
echo "  Dashboard Links"
echo "  ─────────────────────────────────────────────────────────────"
echo "  Coolify:  https://coolify.$DOMAIN_SUFFIX/project/$PROJECT_UUID"
echo "  Gitea:    $GITEA_EXTERNAL_URL/$GITEA_USER/$REPO_NAME"
echo ""
echo "  Test Deployment"
echo "  ─────────────────────────────────────────────────────────────"
echo "  git clone $GITEA_EXTERNAL_URL/$GITEA_USER/$REPO_NAME.git"
echo "  cd $REPO_NAME"
echo "  # Make changes..."
echo "  git add . && git commit -m 'update' && git push"
echo ""
