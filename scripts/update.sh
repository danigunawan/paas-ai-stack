#!/bin/bash
# =============================================================================
# PaaS AI Stack - Update Script
# Unified update mechanism for all services
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
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# Version file location
VERSIONS_FILE="$PROJECT_DIR/data/.versions"

# GitHub API URLs for version checking
OPENCLAW_RELEASES="https://api.github.com/repos/openclaw/openclaw/releases/latest"
GITEA_RELEASES="https://api.github.com/repos/go-gitea/gitea/releases/latest"
N8N_RELEASES="https://api.github.com/repos/n8n-io/n8n/releases/latest"
COOLIFY_RELEASES="https://api.github.com/repos/coollabsio/coolify/releases/latest"
LOBECHAT_RELEASES="https://api.github.com/repos/lobehub/lobe-chat/releases/latest"

# =============================================================================
# FUNCTIONS
# =============================================================================

show_help() {
    echo ""
    echo "PaaS AI Stack - Update Script"
    echo "=============================="
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --all              Update all services (docker images + OpenClaw rebuild)"
    echo "  --openclaw         Update OpenClaw only (rebuild from source)"
    echo "  --images           Update docker images only (pull latest)"
    echo "  --check            Check for available updates without applying"
    echo "  --backup           Create backup before update (auto-enabled for --all)"
    echo "  --version <tag>    Pin OpenClaw to specific version/tag (e.g., v2026.1.30)"
    echo "  --rollback <file>  Rollback to a previous backup"
    echo "  --help             Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --check                    # Check for updates"
    echo "  $0 --all                      # Update everything (with auto-backup)"
    echo "  $0 --openclaw --version v2026.1.30  # Update OpenClaw to specific version"
    echo "  $0 --images                   # Update only docker images"
    echo "  $0 --rollback backups/backup-20260131.tar.gz  # Restore from backup"
    echo ""
}

# Load environment variables
load_env() {
    if [ -f "$PROJECT_DIR/.env" ]; then
        set -a
        source "$PROJECT_DIR/.env"
        set +a
    fi
}

# Ensure data directory exists
ensure_data_dir() {
    mkdir -p "$PROJECT_DIR/data"
    mkdir -p "$PROJECT_DIR/backups"
}

# Get current installed version from container or version file
get_current_version() {
    local service="$1"
    
    # Try to read from versions file first
    if [ -f "$VERSIONS_FILE" ]; then
        local version=$(grep "^${service}=" "$VERSIONS_FILE" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$version" ]; then
            echo "$version"
            return
        fi
    fi
    
    # Fall back to querying containers
    case "$service" in
        openclaw)
            # Try to get version from OpenClaw container
            local ver=$(docker exec openclaw-cli node dist/index.js --version 2>/dev/null | head -1 || echo "unknown")
            echo "$ver"
            ;;
        gitea)
            local ver=$(docker exec gitea gitea --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
            echo "$ver"
            ;;
        n8n)
            local ver=$(docker exec n8n n8n --version 2>/dev/null || echo "unknown")
            echo "$ver"
            ;;
        coolify)
            # Coolify version from image label or API
            local ver=$(docker inspect coolify --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || echo "unknown")
            echo "$ver"
            ;;
        lobechat)
            local ver=$(docker inspect lobe-chat --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || echo "unknown")
            echo "$ver"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Get latest version from GitHub releases
get_latest_version() {
    local service="$1"
    local url=""
    
    case "$service" in
        openclaw) url="$OPENCLAW_RELEASES" ;;
        gitea) url="$GITEA_RELEASES" ;;
        n8n) url="$N8N_RELEASES" ;;
        coolify) url="$COOLIFY_RELEASES" ;;
        lobechat) url="$LOBECHAT_RELEASES" ;;
        *) echo "unknown"; return ;;
    esac
    
    local version=$(curl -s "$url" 2>/dev/null | jq -r '.tag_name // .name // "unknown"' 2>/dev/null || echo "unknown")
    echo "$version"
}

# Update versions file
update_versions_file() {
    log_info "Updating version tracking file..."
    
    ensure_data_dir
    
    cat > "$VERSIONS_FILE" << EOF
# Auto-generated by update script
# Last updated: $(date -Iseconds)
openclaw=$(get_current_version openclaw)
gitea=$(get_current_version gitea)
n8n=$(get_current_version n8n)
coolify=$(get_current_version coolify)
lobechat=$(get_current_version lobechat)
last_check=$(date -Iseconds)
EOF
    
    log_success "Version file updated: $VERSIONS_FILE"
}

# Check for available updates
check_updates() {
    echo ""
    echo "=============================================="
    echo "  Checking for Available Updates"
    echo "=============================================="
    echo ""
    
    local updates_available=false
    
    printf "%-15s %-20s %-20s %s\n" "SERVICE" "CURRENT" "LATEST" "STATUS"
    printf "%-15s %-20s %-20s %s\n" "-------" "-------" "------" "------"
    
    for service in openclaw gitea n8n coolify lobechat; do
        local current=$(get_current_version "$service")
        local latest=$(get_latest_version "$service")
        local status=""
        
        if [ "$current" = "unknown" ] || [ "$latest" = "unknown" ]; then
            status="${YELLOW}unknown${NC}"
        elif [ "$current" = "$latest" ]; then
            status="${GREEN}up-to-date${NC}"
        else
            status="${CYAN}update available${NC}"
            updates_available=true
        fi
        
        printf "%-15s %-20s %-20s " "$service" "$current" "$latest"
        echo -e "$status"
    done
    
    echo ""
    
    if [ "$updates_available" = true ]; then
        log_info "Updates are available. Run '$0 --all' to update."
    else
        log_success "All services are up to date."
    fi
    
    # Update the last check timestamp
    if [ -f "$VERSIONS_FILE" ]; then
        sed -i.bak "s/^last_check=.*/last_check=$(date -Iseconds)/" "$VERSIONS_FILE" 2>/dev/null || true
        rm -f "${VERSIONS_FILE}.bak" 2>/dev/null || true
    fi
}

# Create backup
create_backup() {
    log_step "Creating backup before update..."
    
    ensure_data_dir
    
    local backup_file="$PROJECT_DIR/backups/backup-$(date +%Y%m%d_%H%M%S).tar.gz"
    
    if [ -d "$PROJECT_DIR/data" ] && [ "$(ls -A $PROJECT_DIR/data 2>/dev/null)" ]; then
        tar -czf "$backup_file" -C "$PROJECT_DIR" data/ 2>/dev/null
        log_success "Backup created: $backup_file"
        echo "$backup_file"
    else
        log_warn "No data directory to backup"
        echo ""
    fi
}

# Rollback from backup
do_rollback() {
    local backup_file="$1"
    
    if [ ! -f "$backup_file" ]; then
        log_error "Backup file not found: $backup_file"
        exit 1
    fi
    
    echo ""
    echo "=============================================="
    echo "  Rolling Back from Backup"
    echo "=============================================="
    echo ""
    
    log_warn "This will:"
    echo "  1. Stop all services"
    echo "  2. Replace data/ with backup contents"
    echo "  3. Restart services"
    echo ""
    read -p "Continue? [y/N] " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Rollback cancelled."
        exit 0
    fi
    
    log_step "Stopping services..."
    docker compose down
    
    log_step "Restoring from backup..."
    # Remove current data but keep directory
    rm -rf "$PROJECT_DIR/data.old" 2>/dev/null || true
    if [ -d "$PROJECT_DIR/data" ]; then
        mv "$PROJECT_DIR/data" "$PROJECT_DIR/data.old"
    fi
    
    tar -xzf "$backup_file" -C "$PROJECT_DIR"
    
    log_step "Starting services..."
    docker compose up -d
    
    log_step "Waiting for health checks..."
    sleep 30
    
    # Verify services are healthy
    local unhealthy=$(docker compose ps --format json 2>/dev/null | jq -r 'select(.Health == "unhealthy") | .Name' 2>/dev/null | wc -l || echo "0")
    
    if [ "$unhealthy" -gt 0 ]; then
        log_warn "Some services may be unhealthy. Check with: docker compose ps"
    else
        log_success "All services started successfully"
    fi
    
    # Clean up old data after successful rollback
    rm -rf "$PROJECT_DIR/data.old" 2>/dev/null || true
    
    log_success "Rollback complete!"
    echo ""
    echo "Note: If issues persist, old data is preserved in data.old/"
}

# Update docker images
update_images() {
    log_step "Pulling latest docker images..."
    
    docker compose pull
    
    log_step "Restarting services with new images..."
    docker compose up -d
    
    log_success "Docker images updated"
}

# Update OpenClaw (rebuild from source)
update_openclaw() {
    local version="${1:-main}"
    
    log_step "Updating OpenClaw to version: $version"
    
    # Stop OpenClaw container
    log_info "Stopping OpenClaw container..."
    docker compose stop openclaw-cli
    
    # Rebuild with specified version
    log_info "Building OpenClaw from source (this may take a few minutes)..."
    docker compose build --no-cache --build-arg OPENCLAW_VERSION="$version" openclaw-cli
    
    # Start the container
    log_info "Starting OpenClaw container..."
    docker compose up -d openclaw-cli
    
    # Wait for health check
    log_info "Waiting for OpenClaw to be ready..."
    local retries=0
    local max_retries=30
    
    while [ $retries -lt $max_retries ]; do
        if docker exec openclaw-cli wget --quiet --tries=1 --spider http://localhost:18789/ 2>/dev/null; then
            break
        fi
        retries=$((retries + 1))
        sleep 2
    done
    
    if [ $retries -eq $max_retries ]; then
        log_warn "OpenClaw health check timed out. Check logs with: docker logs openclaw-cli"
    else
        log_success "OpenClaw updated to $version"
    fi
}

# Update all services
update_all() {
    local openclaw_version="${1:-main}"
    
    echo ""
    echo "=============================================="
    echo "  Updating All Services"
    echo "=============================================="
    echo ""
    
    # Create backup first
    create_backup
    
    # Update docker images
    update_images
    
    # Update OpenClaw
    update_openclaw "$openclaw_version"
    
    # Update versions file
    update_versions_file
    
    echo ""
    log_success "All services updated!"
    echo ""
    echo "Run '$0 --check' to verify versions."
}

# =============================================================================
# MAIN
# =============================================================================

# Parse arguments
DO_CHECK=false
DO_ALL=false
DO_IMAGES=false
DO_OPENCLAW=false
DO_BACKUP=false
DO_ROLLBACK=false
OPENCLAW_VERSION=""
ROLLBACK_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            show_help
            exit 0
            ;;
        --check)
            DO_CHECK=true
            shift
            ;;
        --all)
            DO_ALL=true
            shift
            ;;
        --images)
            DO_IMAGES=true
            shift
            ;;
        --openclaw)
            DO_OPENCLAW=true
            shift
            ;;
        --backup)
            DO_BACKUP=true
            shift
            ;;
        --version)
            OPENCLAW_VERSION="$2"
            shift 2
            ;;
        --rollback)
            DO_ROLLBACK=true
            ROLLBACK_FILE="$2"
            shift 2
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Load environment
load_env

# Ensure we have at least one action
if [ "$DO_CHECK" = false ] && [ "$DO_ALL" = false ] && [ "$DO_IMAGES" = false ] && [ "$DO_OPENCLAW" = false ] && [ "$DO_ROLLBACK" = false ]; then
    show_help
    exit 0
fi

# Execute actions
if [ "$DO_ROLLBACK" = true ]; then
    do_rollback "$ROLLBACK_FILE"
    exit 0
fi

if [ "$DO_CHECK" = true ]; then
    check_updates
    exit 0
fi

# For updates, ensure docker is running
if ! docker info &> /dev/null 2>&1; then
    log_error "Docker is not running. Start Docker first."
    exit 1
fi

# Set default OpenClaw version
if [ -z "$OPENCLAW_VERSION" ]; then
    # Check .env for OPENCLAW_VERSION, default to main
    OPENCLAW_VERSION="${OPENCLAW_VERSION:-main}"
fi

if [ "$DO_ALL" = true ]; then
    update_all "$OPENCLAW_VERSION"
elif [ "$DO_IMAGES" = true ]; then
    if [ "$DO_BACKUP" = true ]; then
        create_backup
    fi
    update_images
    update_versions_file
elif [ "$DO_OPENCLAW" = true ]; then
    if [ "$DO_BACKUP" = true ]; then
        create_backup
    fi
    update_openclaw "$OPENCLAW_VERSION"
    update_versions_file
fi

echo ""
log_success "Update complete!"
