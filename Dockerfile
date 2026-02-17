# Build openclaw from source to avoid npm packaging gaps (some dist files are not shipped).
FROM node:22-bookworm AS openclaw-build

# Dependencies needed for openclaw build
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
  && rm -rf /var/lib/apt/lists/*

# Install Bun (openclaw build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /openclaw

# Automatically detect and use the latest stable OpenClaw release tag
# Falls back to v2026.2.15 if detection fails (ensures build reliability)
# Can be overridden by passing --build-arg OPENCLAW_GIT_REF=<tag>
ARG OPENCLAW_GIT_REF
RUN set -eux; \
  if [ -z "${OPENCLAW_GIT_REF:-}" ]; then \
    echo "🔍 Auto-detecting latest OpenClaw stable release..."; \
    OPENCLAW_GIT_REF=$(git ls-remote --tags --sort=v:refname https://github.com/openclaw/openclaw.git | \
      grep -v '\^{}' | \
      grep -E 'refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' | \
      tail -1 | \
      sed 's|.*refs/tags/||' || echo "v2026.2.15"); \
    echo "✓ Auto-detected OpenClaw ${OPENCLAW_GIT_REF}"; \
  else \
    echo "✓ Using pinned OpenClaw ${OPENCLAW_GIT_REF}"; \
  fi; \
  git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .

# Patch: relax version requirements for packages that may reference unpublished versions.
# Apply to all extension package.json files to handle workspace protocol (workspace:*).
RUN set -eux; \
  find ./extensions -name 'package.json' -type f | while read -r f; do \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
  done

RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install
RUN pnpm ui:build

# Verify UI was built successfully (fail build if missing critical files)
RUN set -x && \
    test -d /openclaw/ui/dist && \
    test -f /openclaw/ui/dist/index.html && \
    echo "✓ OpenClaw UI build verified" || \
    (echo "✗ ERROR: OpenClaw UI build failed - missing dist files!" && exit 1)


# Runtime image
FROM node:22-bookworm
ENV NODE_ENV=production

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    build-essential \
    gcc \
    g++ \
    make \
    procps \
    file \
    git \
    python3 \
    pkg-config \
    sudo \
  && rm -rf /var/lib/apt/lists/*

# Install Homebrew (must run as non-root user)
# Create a user for Homebrew installation, install it, then make it accessible to all users
RUN useradd -m -s /bin/bash linuxbrew \
  && echo 'linuxbrew ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

USER linuxbrew
RUN NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

USER root
RUN chown -R root:root /home/linuxbrew/.linuxbrew
ENV PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:${PATH}"

WORKDIR /app

# Wrapper deps
RUN corepack enable
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --prod --frozen-lockfile && pnpm store prune

# Copy built openclaw
COPY --from=openclaw-build /openclaw /openclaw

# Provide a openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw

COPY src ./src

ENV PORT=8080
EXPOSE 8080
CMD ["node", "src/server.js"]
