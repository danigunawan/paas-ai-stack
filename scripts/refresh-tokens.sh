#!/bin/bash
# =============================================================================
# API Token Refresh Script
# =============================================================================
# Regenerates API tokens for Gitea and Coolify when they expire.
#
# Usage: ./refresh-tokens.sh [--gitea] [--coolify] [--all]
#
# Requirements:
#   - ADMIN_USERNAME and ADMIN_PASSWORD in .env
#   - Gitea and Coolify containers running
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Load credentials
load_credentials() {
    if [ -f "$PROJECT_ROOT/paas-ai-stack/.env" ]; then
        ADMIN_USERNAME=$(grep "^ADMIN_USERNAME=" "$PROJECT_ROOT/paas-ai-stack/.env" | cut -d= -f2)
        ADMIN_PASSWORD=$(grep "^ADMIN_PASSWORD=" "$PROJECT_ROOT/paas-ai-stack/.env" | cut -d= -f2)
    fi
    
    if [ -z "$ADMIN_USERNAME" ] || [ -z "$ADMIN_PASSWORD" ]; then
        error "ADMIN_USERNAME and ADMIN_PASSWORD not found in .env"
    fi
}

# Refresh Gitea token
refresh_gitea() {
    log "Refreshing Gitea API token..."
    
    GITEA_URL="${GITEA_URL:-https://gitea.digpulsepi.com}"
    
    # Delete existing token
    OLD_TOKEN_ID=$(curl -s -u "$ADMIN_USERNAME:$ADMIN_PASSWORD" \
        "$GITEA_URL/api/v1/users/$ADMIN_USERNAME/tokens" 2>/dev/null | \
        jq -r '.[] | select(.name == "paas-api") | .id')
    
    if [ -n "$OLD_TOKEN_ID" ]; then
        curl -s -X DELETE -u "$ADMIN_USERNAME:$ADMIN_PASSWORD" \
            "$GITEA_URL/api/v1/users/$ADMIN_USERNAME/tokens/$OLD_TOKEN_ID" >/dev/null
        log "  Deleted old token (ID: $OLD_TOKEN_ID)"
    fi
    
    # Create new token
    NEW_TOKEN=$(curl -s -X POST -u "$ADMIN_USERNAME:$ADMIN_PASSWORD" \
        "$GITEA_URL/api/v1/users/$ADMIN_USERNAME/tokens" \
        -H "Content-Type: application/json" \
        -d '{"name": "paas-api", "scopes": ["all"]}' | jq -r '.sha1 // empty')
    
    if [ -z "$NEW_TOKEN" ]; then
        error "Failed to create Gitea token"
    fi
    
    # Update .env files
    update_env "GITEA_TOKEN" "$NEW_TOKEN"
    
    log "  ✓ New Gitea token: ${NEW_TOKEN:0:10}..."
}

# Refresh Coolify token
refresh_coolify() {
    log "Refreshing Coolify API token..."
    
    # Check if Coolify container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^coolify$"; then
        error "Coolify container is not running"
    fi
    
    # Enable API if disabled
    docker exec coolify php artisan tinker --execute="
        \$settings = \App\Models\InstanceSettings::first();
        if (\$settings && !\$settings->is_api_enabled) {
            \$settings->is_api_enabled = true;
            \$settings->save();
        }
    " 2>/dev/null
    
    # Generate new token
    NEW_TOKEN=$(docker exec coolify php artisan tinker --execute="
        use Illuminate\Support\Str;
        
        \$user = \App\Models\User::first();
        \$team = \App\Models\Team::first();
        
        if (\$user && \$team) {
            \App\Models\PersonalAccessToken::where('name', 'paas-api')->delete();
            
            \$plainTextToken = Str::random(40);
            
            \$token = new \App\Models\PersonalAccessToken();
            \$token->name = 'paas-api';
            \$token->token = hash('sha256', \$plainTextToken);
            \$token->abilities = ['*'];
            \$token->tokenable_type = get_class(\$user);
            \$token->tokenable_id = \$user->id;
            \$token->team_id = \$team->id;
            \$token->save();
            
            echo \$token->id . '|' . \$plainTextToken;
        }
    " 2>/dev/null)
    
    if [ -z "$NEW_TOKEN" ] || [[ "$NEW_TOKEN" != *"|"* ]]; then
        error "Failed to create Coolify token"
    fi
    
    # Update .env files
    update_env "COOLIFY_TOKEN" "$NEW_TOKEN"
    
    log "  ✓ New Coolify token: ${NEW_TOKEN:0:20}..."
}

# Update environment files
update_env() {
    local key="$1"
    local value="$2"
    
    for env_file in "$PROJECT_ROOT/.env" "$PROJECT_ROOT/paas-ai-stack/.env"; do
        if [ -f "$env_file" ]; then
            python3 -c "
import re
with open('$env_file', 'r') as f:
    content = f.read()
content = re.sub(r'^${key}=.*$', '${key}=${value}', content, flags=re.MULTILINE)
with open('$env_file', 'w') as f:
    f.write(content)
" 2>/dev/null || {
                # Fallback if python3 not available
                grep -v "^${key}=" "$env_file" > "$env_file.tmp"
                echo "${key}=${value}" >> "$env_file.tmp"
                mv "$env_file.tmp" "$env_file"
            }
        fi
    done
}

# Verify tokens
verify_tokens() {
    log "Verifying tokens..."
    
    # Source the updated env
    GITEA_TOKEN=$(grep "^GITEA_TOKEN=" "$PROJECT_ROOT/.env" | cut -d= -f2)
    COOLIFY_TOKEN=$(grep "^COOLIFY_TOKEN=" "$PROJECT_ROOT/.env" | cut -d= -f2-)
    
    # Test Gitea
    GITEA_USER=$(curl -s "https://gitea.digpulsepi.com/api/v1/user" \
        -H "Authorization: token $GITEA_TOKEN" 2>/dev/null | jq -r '.login // "FAILED"')
    
    if [ "$GITEA_USER" = "FAILED" ]; then
        warn "Gitea token verification failed"
    else
        log "  ✓ Gitea: authenticated as $GITEA_USER"
    fi
    
    # Test Coolify
    COOLIFY_CHECK=$(curl -s "https://coolify.digpulsepi.com/api/v1/servers" \
        -H "Authorization: Bearer $COOLIFY_TOKEN" 2>/dev/null | jq -r '.[0].name // "FAILED"')
    
    if [ "$COOLIFY_CHECK" = "FAILED" ]; then
        warn "Coolify token verification failed"
    else
        log "  ✓ Coolify: server $COOLIFY_CHECK"
    fi
}

# Main
main() {
    echo "=============================================="
    echo "API Token Refresh"
    echo "=============================================="
    echo ""
    
    load_credentials
    
    REFRESH_GITEA=false
    REFRESH_COOLIFY=false
    
    # Parse args
    for arg in "$@"; do
        case $arg in
            --gitea) REFRESH_GITEA=true ;;
            --coolify) REFRESH_COOLIFY=true ;;
            --all) REFRESH_GITEA=true; REFRESH_COOLIFY=true ;;
            -h|--help)
                echo "Usage: $0 [--gitea] [--coolify] [--all]"
                exit 0
                ;;
        esac
    done
    
    # Default to all if no args
    if [ "$REFRESH_GITEA" = false ] && [ "$REFRESH_COOLIFY" = false ]; then
        REFRESH_GITEA=true
        REFRESH_COOLIFY=true
    fi
    
    [ "$REFRESH_GITEA" = true ] && refresh_gitea
    [ "$REFRESH_COOLIFY" = true ] && refresh_coolify
    
    echo ""
    verify_tokens
    
    echo ""
    echo "=============================================="
    echo "Token refresh complete!"
    echo "=============================================="
}

main "$@"
