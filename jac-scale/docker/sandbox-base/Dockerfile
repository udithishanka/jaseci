FROM python:3.12-slim

# Install system deps (curl, unzip needed for bun + general use)
RUN apt-get update -qq && \
    apt-get install -y -qq curl unzip git > /dev/null 2>&1 && \
    rm -rf /var/lib/apt/lists/*

# Install Bun
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:$PATH"

# Install Jac ecosystem (jac-client from fork for Vite host binding fix)
RUN pip install --no-cache-dir jaclang jac-scale && \
    pip install --no-cache-dir 'jac-client @ git+https://github.com/udithishanka/jaseci.git@feature/sandbox-system#subdirectory=jac-client'

# Pre-warm: ensure jac CLI is available
RUN jac --version

WORKDIR /app
