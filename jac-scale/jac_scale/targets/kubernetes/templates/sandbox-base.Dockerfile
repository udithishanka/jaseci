FROM python:3.12-slim

# Install system deps (curl, unzip needed for bun + general use)
RUN apt-get update -qq && \
    apt-get install -y -qq curl unzip git > /dev/null 2>&1 && \
    rm -rf /var/lib/apt/lists/*

# Install Bun to /usr/local so it's accessible when running as non-root (uid 1000)
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash
ENV PATH="/usr/local/bin:$PATH"

# Install Node.js (agent-browser CLI requires node runtime)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y -qq nodejs > /dev/null 2>&1 && \
    rm -rf /var/lib/apt/lists/*

# Install agent-browser CLI globally + system deps + Chrome (as root)
# Chrome binary lands in /root/.agent-browser/ — sandbox pods run as root
# when security_context is disabled in jac.toml
RUN npm install -g agent-browser && \
    agent-browser install --with-deps

# Create non-root user for security_context (uid 1000)
RUN groupadd -g 1000 jac && useradd -u 1000 -g jac -m -s /bin/bash jac
RUN mkdir -p /app && chown 1000:1000 /app

# Install Jac ecosystem
RUN pip install --no-cache-dir jaclang jac-scale jac-client watchdog

# Pre-warm: ensure jac CLI is available
RUN jac --version

WORKDIR /app
