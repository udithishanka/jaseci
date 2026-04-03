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

# Install Chrome system dependencies (agent-browser --with-deps is unreliable)
RUN apt-get update -qq && \
    apt-get install -y -qq \
    libglib2.0-0 libnss3 libnspr4 libdbus-1-3 libatk1.0-0 libatk-bridge2.0-0 \
    libcups2 libxkbcommon0 libasound2t64 libgbm1 libcairo2 libpango-1.0-0 \
    libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libatspi2.0-0 \
    fonts-liberation xdg-utils > /dev/null 2>&1 && \
    rm -rf /var/lib/apt/lists/*

# Install agent-browser CLI globally (as root)
RUN npm install -g agent-browser

# Create non-root user for security_context (uid 1000)
RUN groupadd -g 1000 jac && useradd -u 1000 -g jac -m -s /bin/bash jac
RUN mkdir -p /app && chown 1000:1000 /app

# Install Chrome binary as jac user so it lands in /home/jac/.agent-browser/
# This allows agent-browser to work when pod runs as non-root (uid 1000)
USER jac
RUN agent-browser install
USER root

# Install Jac ecosystem
RUN pip install --no-cache-dir jaclang jac-scale jac-client byllm watchdog

# Pre-warm: ensure jac CLI is available
RUN jac --version

WORKDIR /app
