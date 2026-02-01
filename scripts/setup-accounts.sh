#!/bin/bash
# =============================================================================
# PaaS AI Stack - Automated Account Setup
# Creates admin accounts for all services using credentials from .env
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load environment variables
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
else
    echo "ERROR: .env file not found at $PROJECT_DIR/.env"
    exit 1
fi

# Validate required variables
if [ -z "$ADMIN_EMAIL" ] || [ -z "$ADMIN_PASSWORD" ] || [ -z "$ADMIN_USERNAME" ]; then
    echo "ERROR: ADMIN_EMAIL, ADMIN_USERNAME, and ADMIN_PASSWORD must be set in .env"
    exit 1
fi

echo "=== PaaS AI Stack Account Setup ==="
echo "Admin: $ADMIN_USERNAME <$ADMIN_EMAIL>"
echo ""

# -----------------------------------------------------------------------------
# Wait for services
# -----------------------------------------------------------------------------
wait_for_service() {
    local name=$1
    local url=$2
    local max_attempts=${3:-30}
    local attempt=1
    
    echo -n "Waiting for $name..."
    while [ $attempt -le $max_attempts ]; do
        if curl -sf "$url" > /dev/null 2>&1; then
            echo " ready"
            return 0
        fi
        echo -n "."
        sleep 2
        attempt=$((attempt + 1))
    done
    echo " timeout"
    return 1
}

# -----------------------------------------------------------------------------
# Gitea Admin Setup
# -----------------------------------------------------------------------------
setup_gitea() {
    echo ""
    echo "--- Gitea Admin Setup ---"
    
    # Check if admin exists
    EXISTING=$(docker exec gitea gitea admin user list --admin 2>/dev/null | grep -c "$ADMIN_USERNAME" || true)
    
    if [ "$EXISTING" -gt 0 ]; then
        echo "Gitea admin '$ADMIN_USERNAME' already exists"
    else
        echo "Creating Gitea admin user..."
        docker exec gitea gitea admin user create \
            --username "$ADMIN_USERNAME" \
            --password "$ADMIN_PASSWORD" \
            --email "$ADMIN_EMAIL" \
            --admin \
            --must-change-password=false
        echo "Gitea admin created successfully"
    fi
    
    # Generate access token for API
    echo "Generating Gitea API token..."
    TOKEN_RESULT=$(docker exec gitea gitea admin user generate-access-token \
        --username "$ADMIN_USERNAME" \
        --token-name "paas-setup-$(date +%s)" \
        --scopes "all" 2>&1 || true)
    
    if echo "$TOKEN_RESULT" | grep -q "Access token was successfully created"; then
        GITEA_TOKEN=$(echo "$TOKEN_RESULT" | grep -oP '(?<=: )[a-f0-9]+$' || true)
        if [ -n "$GITEA_TOKEN" ]; then
            echo "GITEA_TOKEN=$GITEA_TOKEN"
            echo ""
            echo "Add to .env: GITEA_TOKEN=$GITEA_TOKEN"
        fi
    else
        echo "Token generation skipped (may already exist)"
    fi
}

# -----------------------------------------------------------------------------
# Casdoor Setup (update admin password + create LobeChat app)
# -----------------------------------------------------------------------------
setup_casdoor() {
    echo ""
    echo "--- Casdoor Setup ---"
    
    CASDOOR_URL="http://127.0.0.1:8000"
    
    # Wait for Casdoor
    if ! wait_for_service "Casdoor" "$CASDOOR_URL/api/health"; then
        echo "Casdoor not ready, skipping..."
        return 1
    fi
    
    # Login with default credentials
    echo "Logging in with default credentials..."
    LOGIN_RESPONSE=$(curl -sf -X POST "$CASDOOR_URL/api/login" \
        -H "Content-Type: application/json" \
        -d '{
            "application": "app-built-in",
            "organization": "built-in",
            "username": "admin",
            "password": "123",
            "type": "login"
        }' 2>/dev/null || true)
    
    if echo "$LOGIN_RESPONSE" | grep -q "error"; then
        echo "Default login failed - password may already be changed"
        echo "Login manually at https://$CASDOOR_DOMAIN with admin credentials"
        return 0
    fi
    
    # Extract token
    ACCESS_TOKEN=$(echo "$LOGIN_RESPONSE" | grep -oP '"accessToken"\s*:\s*"\K[^"]+' || true)
    
    if [ -z "$ACCESS_TOKEN" ]; then
        echo "Could not get access token, manual setup required"
        return 0
    fi
    
    # Update admin password
    echo "Updating admin password..."
    curl -sf -X POST "$CASDOOR_URL/api/set-password" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"userOwner\": \"built-in\",
            \"userName\": \"admin\",
            \"oldPassword\": \"123\",
            \"newPassword\": \"$ADMIN_PASSWORD\"
        }" > /dev/null 2>&1 || true
    echo "Admin password updated"
    
    # Generate client credentials for LobeChat
    CLIENT_ID="lobechat-$(openssl rand -hex 8)"
    CLIENT_SECRET=$(openssl rand -hex 32)
    
    # Create LobeChat application
    echo "Creating LobeChat application..."
    APP_RESPONSE=$(curl -sf -X POST "$CASDOOR_URL/api/add-application?id=admin/lobechat" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"owner\": \"admin\",
            \"name\": \"lobechat\",
            \"displayName\": \"LobeChat\",
            \"organization\": \"built-in\",
            \"clientId\": \"$CLIENT_ID\",
            \"clientSecret\": \"$CLIENT_SECRET\",
            \"redirectUris\": [\"https://$LOBE_DOMAIN/api/auth/callback/casdoor\"],
            \"enablePassword\": true,
            \"enableSignUp\": true
        }" 2>/dev/null || true)
    
    if echo "$APP_RESPONSE" | grep -q "error"; then
        echo "Application may already exist"
    else
        echo "LobeChat application created"
        echo ""
        echo "Add to .env:"
        echo "CASDOOR_CLIENT_ID=$CLIENT_ID"
        echo "CASDOOR_CLIENT_SECRET=$CLIENT_SECRET"
    fi
}

# -----------------------------------------------------------------------------
# Coolify Setup
# -----------------------------------------------------------------------------
setup_coolify() {
    echo ""
    echo "--- Coolify Setup ---"
    
    COOLIFY_URL="http://127.0.0.1:8080"
    
    # Wait for Coolify
    if ! wait_for_service "Coolify" "$COOLIFY_URL/api/health"; then
        echo "Coolify not ready, skipping..."
        return 1
    fi
    
    # Check if registration is needed
    echo "Checking Coolify status..."
    HEALTH=$(curl -sf "$COOLIFY_URL/api/health" 2>/dev/null || echo "{}")
    
    # Try to register first user
    echo "Attempting to register first user..."
    REGISTER_RESPONSE=$(curl -sf -X POST "$COOLIFY_URL/api/v1/register" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$ADMIN_USERNAME\",
            \"email\": \"$ADMIN_EMAIL\",
            \"password\": \"$ADMIN_PASSWORD\",
            \"password_confirmation\": \"$ADMIN_PASSWORD\"
        }" 2>/dev/null || true)
    
    if echo "$REGISTER_RESPONSE" | grep -q "token"; then
        echo "Coolify admin registered successfully"
        COOLIFY_TOKEN=$(echo "$REGISTER_RESPONSE" | grep -oP '"token"\s*:\s*"\K[^"]+' || true)
        if [ -n "$COOLIFY_TOKEN" ]; then
            echo ""
            echo "Add to .env: COOLIFY_TOKEN=$COOLIFY_TOKEN"
        fi
    elif echo "$REGISTER_RESPONSE" | grep -q "already"; then
        echo "Coolify admin already exists"
    else
        echo "Coolify registration: complete setup at https://$COOLIFY_DOMAIN"
    fi
}

# -----------------------------------------------------------------------------
# n8n Setup (handled via env vars, just verify)
# -----------------------------------------------------------------------------
setup_n8n() {
    echo ""
    echo "--- n8n Setup ---"
    echo "n8n auto-creates owner from N8N_DEFAULT_USER_EMAIL/PASSWORD env vars"
    echo "Login at: https://$N8N_DOMAIN"
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "=== Setup Complete ==="
    echo ""
    echo "Service URLs:"
    echo "  Gitea:    https://$GITEA_DOMAIN"
    echo "  Coolify:  https://$COOLIFY_DOMAIN"
    echo "  n8n:      https://$N8N_DOMAIN"
    echo "  LobeChat: https://$LOBE_DOMAIN"
    echo "  Casdoor:  https://$CASDOOR_DOMAIN"
    echo ""
    echo "Login credentials:"
    echo "  Username: $ADMIN_USERNAME"
    echo "  Email:    $ADMIN_EMAIL"
    echo "  Password: (from ADMIN_PASSWORD in .env)"
    echo ""
    echo "NOTE: Update .env with any generated tokens shown above,"
    echo "then run: docker compose up -d"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    setup_gitea
    setup_casdoor
    setup_coolify
    setup_n8n
    print_summary
}

main "$@"
