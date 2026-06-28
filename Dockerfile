# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# Vernify Bootstrap Container
#
# Ephemeral control-plane-of-one for the Vernify homelab greenfield bootstrap.
# Carries the minimal toolchain needed for Phases 1-5 of the greenfield standup.
# Retired once Jenkins and Vault can carry secrets and automation themselves.
#
# Baked tools:
#   ansible-core, blueprints.* collections (requirements.yml)
#   packer, terraform, vault CLI, step CLI, jq, git, ssh-client
# ---------------------------------------------------------------------------
FROM ubuntu:24.04

LABEL org.opencontainers.image.title="Vernify Bootstrap Container"
LABEL org.opencontainers.image.description="Ephemeral Phase-0 bootstrap toolchain for the Vernify homelab."
LABEL org.opencontainers.image.source="https://github.com/Vernify/bootstrap-container"
LABEL org.opencontainers.image.licenses="MIT"

# ── pinned tool versions ────────────────────────────────────────────────────
ARG PACKER_VERSION=1.11.2
ARG TERRAFORM_VERSION=1.9.8
ARG VAULT_VERSION=1.17.5
ARG STEP_VERSION=0.27.4
ARG ARCH=amd64

ENV DEBIAN_FRONTEND=noninteractive

# ── system dependencies ─────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        openssh-client \
        python3 \
        python3-pip \
        python3-venv \
        sshpass \
        unzip \
        wget \
        xorriso \
    && rm -rf /var/lib/apt/lists/*

# ── ansible-core (via pip into a venv to avoid system-pip conflicts) ────────
ENV VIRTUAL_ENV=/opt/ansible-venv
RUN python3 -m venv "${VIRTUAL_ENV}" \
    && "${VIRTUAL_ENV}/bin/pip" install --no-cache-dir \
        ansible-core==2.17.* \
        hvac \
        netaddr
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

# ── packer ──────────────────────────────────────────────────────────────────
RUN curl -fsSL "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_${ARCH}.zip" \
        -o /tmp/packer.zip \
    && unzip -o /tmp/packer.zip -d /usr/local/bin/ \
    && rm /tmp/packer.zip \
    && packer version

# ── terraform ───────────────────────────────────────────────────────────────
RUN curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip" \
        -o /tmp/terraform.zip \
    && unzip -o /tmp/terraform.zip -d /usr/local/bin/ \
    && rm /tmp/terraform.zip \
    && terraform version

# ── vault CLI ───────────────────────────────────────────────────────────────
RUN curl -fsSL "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_${ARCH}.zip" \
        -o /tmp/vault.zip \
    && unzip -o /tmp/vault.zip -d /usr/local/bin/ \
    && rm /tmp/vault.zip \
    && vault version

# ── step CLI ────────────────────────────────────────────────────────────────
RUN mkdir -p /tmp/step-extract \
    && curl -fsSL "https://github.com/smallstep/cli/releases/download/v${STEP_VERSION}/step_linux_${STEP_VERSION}_${ARCH}.tar.gz" \
        -o /tmp/step.tar.gz \
    && tar -xzf /tmp/step.tar.gz -C /tmp/step-extract/ \
    && find /tmp/step-extract -name "step" -type f -exec mv {} /usr/local/bin/ \; \
    && rm -rf /tmp/step* \
    && step version

# ── Ansible Galaxy collections (blueprints.*) ───────────────────────────────
WORKDIR /bootstrap
COPY requirements.yml ./
RUN ansible-galaxy collection install -r requirements.yml --force \
    && ansible-galaxy collection list

# ── entrypoint ──────────────────────────────────────────────────────────────
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
