#!/usr/bin/env bash
# ===========================================================================
# Vernify Bootstrap Container — entrypoint
#
# Checks for all required secrets, prompts interactively for any that are
# missing, writes the SSH key to disk if supplied via env, then drops the
# operator into a bash shell with all tools on $PATH.
#
# All secrets supplied here are TRANSIENT — they are seeded into Vault during
# Phase 3 and the container is retired at Phase 5.
# ===========================================================================
set -euo pipefail

readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly GREEN='\033[0;32m'
readonly CYAN='\033[0;36m'
readonly RESET='\033[0m'

_info()    { echo -e "${CYAN}[bootstrap]${RESET} $*"; }
_warn()    { echo -e "${YELLOW}[bootstrap] WARN${RESET} $*"; }
_success() { echo -e "${GREEN}[bootstrap]${RESET} $*"; }
_error()   { echo -e "${RED}[bootstrap] ERROR${RESET} $*" >&2; }

# ---------------------------------------------------------------------------
# prompt_if_missing <VAR_NAME> <description> [secret=false]
#
# If the named variable is unset or empty, reads a value from stdin.
# secret=true suppresses echo (read -rs).
# ---------------------------------------------------------------------------
prompt_if_missing() {
  local var="$1"
  local description="$2"
  local secret="${3:-false}"

  if [[ -n "${!var:-}" ]]; then
    _info "${var} already set — skipping prompt."
    return
  fi

  echo ""
  if [[ "${secret}" == "true" ]]; then
    read -rsp "  Enter ${description} (${var}): " _tmp_val
    echo ""   # newline after silent read
  else
    read -rp  "  Enter ${description} (${var}): " _tmp_val
  fi

  if [[ -z "${_tmp_val}" ]]; then
    _error "${var} is required but was left blank."
    exit 1
  fi

  # Export into the current shell and all children.
  # This uses printf + eval to safely handle special characters.
  printf -v "${var}" '%s' "${_tmp_val}"
  export "${var?}"
  unset _tmp_val
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${CYAN}  Vernify Bootstrap Container — Phase 0${RESET}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
_info "Checking required secrets…"
echo ""

# ---------------------------------------------------------------------------
# Required secrets — prompt for any that are missing.
# ---------------------------------------------------------------------------

# Proxmox
prompt_if_missing PROXMOX_URL \
  "Proxmox URL (e.g. https://proxmox.home.vernify.io:8006)"

prompt_if_missing PROXMOX_TOKEN_ID \
  "Proxmox API token ID (e.g. root@pam!bootstrap)"

prompt_if_missing PROXMOX_TOKEN_SECRET \
  "Proxmox API token secret (UUID)" true

# Terraform Cloud
prompt_if_missing TFC_TOKEN \
  "Terraform Cloud team token" true

# Git
prompt_if_missing GIT_PAT \
  "GitHub PAT for the Vernify org (read access to repos)" true

# step-ca PKI
prompt_if_missing STEP_CA_PROVISIONER_PASSWORD \
  "step-ca provisioner password (used in Phase 3)" true

# SSH — private key can be supplied as a base64-encoded env var OR mounted
# at /run/secrets/bootstrap_ssh_key.  If neither is present, warn rather
# than hard-fail so the operator can still use agent forwarding.
SSH_KEY_FILE="${BOOTSTRAP_SSH_KEY_FILE:-/run/secrets/bootstrap_ssh_key}"

if [[ -n "${BOOTSTRAP_SSH_PRIVATE_KEY_B64:-}" ]]; then
  _info "Decoding SSH private key from BOOTSTRAP_SSH_PRIVATE_KEY_B64…"
  mkdir -p /root/.ssh
  printf '%s' "${BOOTSTRAP_SSH_PRIVATE_KEY_B64}" | base64 -d > /root/.ssh/id_vernify_bootstrap
  chmod 600 /root/.ssh/id_vernify_bootstrap
  SSH_KEY_FILE="/root/.ssh/id_vernify_bootstrap"
elif [[ -f "${SSH_KEY_FILE}" ]]; then
  _info "Using SSH key mounted at ${SSH_KEY_FILE}."
  cp "${SSH_KEY_FILE}" /root/.ssh/id_vernify_bootstrap
  chmod 600 /root/.ssh/id_vernify_bootstrap
  SSH_KEY_FILE="/root/.ssh/id_vernify_bootstrap"
else
  _warn "No SSH key provided via BOOTSTRAP_SSH_PRIVATE_KEY_B64 or mount at ${SSH_KEY_FILE}."
  _warn "Set it before running Ansible against provisioned VMs."
fi

# Configure ssh-agent if we have a key
if [[ -f "${SSH_KEY_FILE:-}" ]]; then
  eval "$(ssh-agent -s)" > /dev/null
  ssh-add "${SSH_KEY_FILE}" 2>/dev/null || _warn "ssh-add failed — check key format."
fi

# ---------------------------------------------------------------------------
# Export convenience aliases used by various tools
# ---------------------------------------------------------------------------
export VAULT_ADDR="${VAULT_ADDR:-}"           # populated in Phase 3 once Vault is up
export VAULT_TOKEN="${VAULT_TOKEN:-}"
# TF_TOKEN_app_terraform_io is the env var that Terraform / TFC recognises.
export TF_TOKEN_app_terraform_io="${TFC_TOKEN}"

# ---------------------------------------------------------------------------
# Validate the toolchain is intact
# ---------------------------------------------------------------------------
echo ""
_info "Toolchain versions:"
ansible --version       | head -1
packer version          | head -1
terraform version       | head -1
vault version           | head -1
step version 2>&1       | head -1
jq --version

echo ""
_success "Bootstrap environment ready.  Type 'exit' to tear down this container."
echo ""

# ---------------------------------------------------------------------------
# Drop into an interactive bash shell
# ---------------------------------------------------------------------------
exec bash --login
