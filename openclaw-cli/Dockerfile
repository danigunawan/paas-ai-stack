# Build OpenClaw from source
# Works on both ARM64 (Apple Silicon, Raspberry Pi) and x86_64
FROM node:22-bookworm

# Enable corepack for pnpm
RUN corepack enable

# Install required tools
RUN apt-get update && \
    apt-get install -y --no-install-recommends wget git ca-certificates openssh-client jq && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Clone the OpenClaw repository
# Use ARG to allow overriding version at build time (default: latest main branch)
ARG OPENCLAW_VERSION=main
RUN git clone --depth 1 --branch ${OPENCLAW_VERSION} https://github.com/openclaw/openclaw.git .

# Install dependencies (use --no-frozen-lockfile due to upstream lockfile issues)
RUN pnpm install --no-frozen-lockfile

# Build the application (skip bun-related scripts if they fail)
ENV OPENCLAW_A2UI_SKIP_MISSING=1
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm build || echo "Build warning - continuing..."

# Build the UI (force pnpm for ARM compatibility)
RUN pnpm ui:install || echo "UI install warning - continuing..."
RUN pnpm ui:build || echo "UI build warning - continuing..."

ENV NODE_ENV=production

# Create directories for config and workspace
RUN mkdir -p /root/.openclaw /root/openclaw-workspace

# Copy and set up entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Use entrypoint for automatic onboarding
ENTRYPOINT ["/entrypoint.sh"]

# Default command - run gateway directly with node (no systemd needed)
CMD ["node", "dist/index.js", "gateway", "--bind", "lan", "--port", "18789"]
