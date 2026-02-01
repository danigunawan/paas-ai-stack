#!/bin/bash
set -e

# =============================================================================
# OpenClaw Entrypoint Script (v2026.1.30+)
# =============================================================================
# Uses FREE Kimi K2.5 (synthetic provider) as the primary model.
# Optional API keys (Anthropic, OpenRouter, etc.) are configured as fallbacks.
# No API key is required - OpenClaw works out of the box with free models!
# =============================================================================

ONBOARD_MARKER="/root/.openclaw/.onboarded"

# Function to run onboard
run_onboard() {
    echo "=============================================="
    echo "OpenClaw Auto-Onboarding (v2026.1.30)"
    echo "=============================================="
    echo "Primary model: Kimi K2.5 (FREE - no API key required)"
    echo ""
    
    # Determine which auth to use for onboarding
    # Priority: Use any available paid key for initial setup, or skip auth for synthetic-only
    local auth_choice=""
    local api_key=""
    local onboard_provider=""
    
    if [ -n "$ANTHROPIC_API_KEY" ]; then
        echo "✓ Found ANTHROPIC_API_KEY - will configure as fallback"
        auth_choice="apiKey"
        api_key="$ANTHROPIC_API_KEY"
        onboard_provider="anthropic"
    elif [ -n "$OPENROUTER_API_KEY" ]; then
        echo "✓ Found OPENROUTER_API_KEY - will configure as fallback"
        auth_choice="openrouter-api-key"
        api_key="$OPENROUTER_API_KEY"
        onboard_provider="openrouter"
    elif [ -n "$OPENAI_API_KEY" ]; then
        echo "✓ Found OPENAI_API_KEY - will configure as fallback"
        auth_choice="openai-api-key"
        api_key="$OPENAI_API_KEY"
        onboard_provider="openai"
    elif [ -n "$GEMINI_API_KEY" ]; then
        echo "✓ Found GEMINI_API_KEY - will configure as fallback"
        auth_choice="gemini-api-key"
        api_key="$GEMINI_API_KEY"
        onboard_provider="google"
    else
        echo "ℹ No paid API keys found - using FREE tier only"
        onboard_provider="synthetic"
    fi
    
    # Run onboarding based on available provider
    echo "Running onboarding..."
    if [ "$onboard_provider" = "synthetic" ]; then
        # Synthetic/free-only mode - minimal onboarding
        node dist/index.js onboard \
            --non-interactive \
            --accept-risk \
            --flow quickstart \
            --skip-channels \
            --skip-skills \
            --skip-daemon \
            --skip-ui \
            --skip-health 2>/dev/null || {
            echo "⚠ Basic onboard returned non-zero, continuing with config..."
        }
    else
        # Onboard with the available paid provider
        case "$onboard_provider" in
            anthropic)
                node dist/index.js onboard \
                    --non-interactive \
                    --accept-risk \
                    --flow quickstart \
                    --auth-choice "$auth_choice" \
                    --token-provider "$onboard_provider" \
                    --token "$api_key" \
                    --skip-channels \
                    --skip-skills \
                    --skip-daemon \
                    --skip-ui \
                    --skip-health
                ;;
            openrouter)
                node dist/index.js onboard \
                    --non-interactive \
                    --accept-risk \
                    --flow quickstart \
                    --auth-choice openrouter-api-key \
                    --openrouter-api-key "$api_key" \
                    --skip-channels \
                    --skip-skills \
                    --skip-daemon \
                    --skip-ui \
                    --skip-health
                ;;
            openai)
                node dist/index.js onboard \
                    --non-interactive \
                    --accept-risk \
                    --flow quickstart \
                    --auth-choice openai-api-key \
                    --openai-api-key "$api_key" \
                    --skip-channels \
                    --skip-skills \
                    --skip-daemon \
                    --skip-ui \
                    --skip-health
                ;;
            google)
                node dist/index.js onboard \
                    --non-interactive \
                    --accept-risk \
                    --flow quickstart \
                    --auth-choice gemini-api-key \
                    --gemini-api-key "$api_key" \
                    --skip-channels \
                    --skip-skills \
                    --skip-daemon \
                    --skip-ui \
                    --skip-health
                ;;
        esac || {
            echo "⚠ Onboard returned non-zero, but continuing..."
        }
    fi
    
    # ==========================================================================
    # Configure FREE Kimi K2.5 as PRIMARY model
    # ==========================================================================
    echo ""
    echo "Configuring FREE Kimi K2.5 as primary model..."
    
    # Set Kimi K2.5 (synthetic provider - FREE) as the primary model
    node dist/index.js models set "synthetic/hf:moonshotai/Kimi-K2.5" 2>/dev/null || {
        # Fallback to Kimi K2 Instruct if K2.5 not available
        node dist/index.js models set "synthetic/hf:moonshotai/Kimi-K2-Instruct-0905" 2>/dev/null || true
    }
    
    # ==========================================================================
    # Configure paid API keys as FALLBACKS (if provided)
    # ==========================================================================
    echo "Configuring fallback models..."
    
    # Add Anthropic as fallback if key provided
    if [ -n "$ANTHROPIC_API_KEY" ]; then
        echo "  + Adding Anthropic Claude as fallback"
        node dist/index.js models fallbacks add "anthropic/claude-sonnet-4-20250514" 2>/dev/null || \
        node dist/index.js models fallbacks add "anthropic/claude-3.5-sonnet" 2>/dev/null || true
    fi
    
    # Add OpenRouter models as fallback if key provided
    if [ -n "$OPENROUTER_API_KEY" ]; then
        echo "  + Adding OpenRouter models as fallback"
        node dist/index.js models fallbacks add "openrouter/anthropic/claude-3.5-sonnet" 2>/dev/null || true
        node dist/index.js models fallbacks add "openrouter/google/gemini-2.0-flash-001" 2>/dev/null || true
    fi
    
    # Add OpenAI as fallback if key provided
    if [ -n "$OPENAI_API_KEY" ]; then
        echo "  + Adding OpenAI GPT-4o as fallback"
        node dist/index.js models fallbacks add "openai/gpt-4o" 2>/dev/null || true
    fi
    
    # Add Gemini as fallback if key provided
    if [ -n "$GEMINI_API_KEY" ]; then
        echo "  + Adding Google Gemini as fallback"
        node dist/index.js models fallbacks add "google/gemini-2.0-flash" 2>/dev/null || true
    fi
    
    # Add DeepSeek as fallback if key provided
    if [ -n "$DEEPSEEK_API_KEY" ]; then
        echo "  + Adding DeepSeek as fallback"
        node dist/index.js config set env.DEEPSEEK_API_KEY "$DEEPSEEK_API_KEY" 2>/dev/null || true
        node dist/index.js models fallbacks add "deepseek/deepseek-chat" 2>/dev/null || true
    fi
    
    # ==========================================================================
    # Gateway configuration
    # ==========================================================================
    echo ""
    echo "Configuring gateway..."
    
    # Configure HTTP API endpoint (required for OpenAI-compatible API)
    node dist/index.js config set gateway.http.endpoints.chatCompletions.enabled true 2>/dev/null || true
    
    # Use gateway token from env if provided (override the auto-generated one)
    if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
        echo "  Setting gateway token from OPENCLAW_GATEWAY_TOKEN..."
        node dist/index.js config set gateway.auth.token "$OPENCLAW_GATEWAY_TOKEN" 2>/dev/null || true
    fi
    
    # Set bind to lan for container access
    node dist/index.js config set gateway.bind lan 2>/dev/null || true
    
    # ==========================================================================
    # Memory and session configuration
    # ==========================================================================
    echo "Configuring memory settings..."
    
    # Configure memory flush before compaction
    node dist/index.js config set agents.defaults.compaction.memoryFlush.enabled true 2>/dev/null || true
    
    # Configure session memory search (experimental)
    node dist/index.js config set memorySearch.experimental.sessionMemory true 2>/dev/null || true
    node dist/index.js config set 'memorySearch.sources' '["memory", "sessions"]' 2>/dev/null || true
    
    # ==========================================================================
    # Channel configuration
    # ==========================================================================
    
    # Configure Telegram channel if token is provided
    if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        echo "Configuring Telegram channel..."
        node dist/index.js config set channels.telegram.enabled true 2>/dev/null || true
        node dist/index.js config set channels.telegram.botToken "$TELEGRAM_BOT_TOKEN" 2>/dev/null || true
        node dist/index.js config set channels.telegram.dmPolicy pairing 2>/dev/null || true
    fi
    
    # ==========================================================================
    # Tools configuration
    # ==========================================================================
    
    # Configure Brave Search if API key is provided
    if [ -n "$BRAVE_API_KEY" ]; then
        echo "Enabling web search (Brave)..."
        node dist/index.js config set tools.web.search.enabled true 2>/dev/null || true
        node dist/index.js config set tools.web.search.apiKey "$BRAVE_API_KEY" 2>/dev/null || true
    fi
    
    # Mark as onboarded
    touch "$ONBOARD_MARKER"
    
    echo ""
    echo "=============================================="
    echo "✓ Onboarding complete!"
    echo "=============================================="
    echo "Primary model: Kimi K2.5 (FREE)"
    if [ -n "$ANTHROPIC_API_KEY" ] || [ -n "$OPENROUTER_API_KEY" ] || [ -n "$OPENAI_API_KEY" ] || [ -n "$GEMINI_API_KEY" ]; then
        echo "Fallbacks: Configured from provided API keys"
    fi
    echo "=============================================="
}

# Check if onboarding is needed
if [ ! -f "$ONBOARD_MARKER" ]; then
    echo "First run detected - running onboarding..."
    run_onboard
else
    echo "✓ Already onboarded, starting gateway..."
fi

# Execute the main command
exec "$@"
