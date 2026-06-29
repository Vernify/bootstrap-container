#!/bin/bash

##############################################################################
# Unified Bootstrap Script: Vernify Phases 3, 4, 5
#
# Purpose: Orchestrate complete homelab bootstrap in a single idempotent
# script. Each phase is delegated to an Ansible orchestration playbook
# (playbooks/phase-{3,4,5}-orchestrate.yml); this script's job is:
#   - pre-flight validation
#   - Terraform provisioning of the three Proxmox targets
#   - dynamic Ansible inventory generation from Terraform outputs
#   - invoking the phase playbooks with the right extra-vars
#   - per-phase completion markers for idempotent re-runs
#   - the top-level operator gate before Vault unseal-key generation
#
# Phases:
#   Pre-phase: terraform-workspaces-deploy creates the sec01/docker01/agent01
#              TFC workspaces so the per-host repos below have a TFC backend
#              to initialize against (runs once, before Phase 3).
#   Phase 3: sec01  (step-ca + Vault) standup + secret seeding
#   Phase 4: docker01 (Jenkins, deployed from terraform-build01-deploy)
#   Phase 5: agent01 (LXC: Jenkins agent + Vault agent + toolchain)
#
# Environment variables (see bootstrap-container/.env.example):
#   PROXMOX_URL                      Proxmox API URL (e.g. https://pve08.vernify.com:8006)
#   PROXMOX_USER                     Proxmox user (e.g. root@pam)
#   PROXMOX_PASSWORD                 Proxmox password
#   TFC_TOKEN                        Terraform Cloud team token
#   GIT_PAT                          GitHub PAT (collection/IaC repo access)
#   STEP_CA_PROVISIONER_PASSWORD     step-ca provisioner password
#   BOOTSTRAP_SSH_PRIVATE_KEY_B64    Base64-encoded SSH private key (or mount BOOTSTRAP_SSH_KEY_FILE)
#   VAULT_ADDR                       Vault API address (default: https://sec01.vernify.internal:8200)
#
# Optional:
#   JENKINS_ADMIN_TOKEN               Jenkins admin API token (auto-generated if unset — see Phase 4)
#   WORKSPACE                         Path containing sibling repos (default: /workspace)
#   BOOTSTRAP_STATE_DIR               Where completion markers are written (default: $BOOTSTRAP_DIR/.state)
#
# Usage:
#   ./scripts/bootstrap-phase-3-5.sh [--only-phase 3|4|5] [--reset-phase 3|4|5]
#
##############################################################################

set -euo pipefail
IFS=$'\n\t'

# Script metadata
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(dirname "$SCRIPT_DIR")"
WORKSPACE="${WORKSPACE:-/workspace}"
STATE_DIR="${BOOTSTRAP_STATE_DIR:-${BOOTSTRAP_DIR}/.state}"
SSH_KEY_FILE="${BOOTSTRAP_SSH_KEY_FILE:-/root/.ssh/id_vernify_bootstrap}"

# Static network plan (see BLUEPRINTS_PHASE_3_5_ARCHITECTURE.md §2)
# NOTE: these are placeholder defaults overwritten by the actual Terraform
# outputs once each phase's "provision" step runs (see tf_output calls below).
SEC01_IP="192.168.22.51"
DOCKER01_IP="192.168.22.52"
AGENT01_IP="192.168.22.53"
CI_USER="ubuntu"      # cloud-init user on sec01/docker01 VMs (terraform-proxmox-vm default)

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

error_exit() {
  log_error "$@"
  exit 1
}

# ----------------------------------------------------------------------------
# Idempotency markers
#
# Each phase step writes a marker file on success. Re-running the script
# checks for the marker first and skips the step if present. This is in
# addition to (not a replacement for) the idempotency checks already built
# into the Ansible roles/playbooks (e.g. init_and_unseal checks Vault's own
# on-disk storage). The markers let the *shell orchestration* (terraform
# apply, ansible-playbook invocation) be skipped without re-running Ansible
# at all, which matters because the playbooks include interactive operator
# gates that should not re-prompt on a no-op re-run.
# ----------------------------------------------------------------------------
marker_path() {
  echo "${STATE_DIR}/$1.done"
}

is_done() {
  [[ -f "$(marker_path "$1")" ]]
}

mark_done() {
  mkdir -p "${STATE_DIR}"
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$(marker_path "$1")"
}

run_step() {
  local marker="$1"
  shift
  if is_done "${marker}"; then
    log_warn "Skipping '${marker}' (already completed; marker: $(marker_path "${marker}"))"
    return 0
  fi
  "$@"
  mark_done "${marker}"
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
ONLY_PHASE=""

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --only-phase)
        ONLY_PHASE="$2"
        shift 2
        ;;
      --reset-phase)
        reset_phase_markers "$2"
        shift 2
        ;;
      --help)
        show_help
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        show_help
        exit 1
        ;;
    esac
  done
}

show_help() {
  cat << EOF
Usage: bootstrap-phase-3-5.sh [OPTIONS]

Unified bootstrap orchestration for Vernify Phases 3, 4, 5.

OPTIONS:
  --only-phase N      Run only phase N (3, 4, or 5). Useful for retrying a single phase.
  --reset-phase N      Delete completion markers for phase N, then exit (forces re-run on next invocation).
  --help               Show this help message

All secrets are read from the environment (see .env.example):
  PROXMOX_URL, PROXMOX_USER, PROXMOX_PASSWORD, TFC_TOKEN, GIT_PAT,
  STEP_CA_PROVISIONER_PASSWORD, BOOTSTRAP_SSH_PRIVATE_KEY_B64, VAULT_ADDR

EOF
}

reset_phase_markers() {
  local phase="$1"
  rm -f "${STATE_DIR}"/phase"${phase}"_*.done
  log_success "Cleared completion markers for phase ${phase}"
}

# ----------------------------------------------------------------------------
# Pre-flight validation
# ----------------------------------------------------------------------------
validate_environment() {
  log_info "=== PRE-FLIGHT VALIDATION ==="

  local missing=()
  for var in PROXMOX_URL PROXMOX_USER PROXMOX_PASSWORD TFC_TOKEN STEP_CA_PROVISIONER_PASSWORD; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("${var}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    error_exit "Missing required environment variables: ${missing[*]} (see .env.example)"
  fi

  if [[ -z "${BOOTSTRAP_SSH_PRIVATE_KEY_B64:-}" && ! -f "${SSH_KEY_FILE}" ]]; then
    error_exit "No SSH key available: set BOOTSTRAP_SSH_PRIVATE_KEY_B64 or mount a key at ${SSH_KEY_FILE}"
  fi

  VAULT_ADDR="${VAULT_ADDR:-https://sec01.vernify.internal:8200}"
  export VAULT_ADDR

  log_success "All required environment variables present"

  for cmd in terraform ansible-playbook vault step jq; do
    if ! command -v "$cmd" &> /dev/null; then
      error_exit "Required command not found: $cmd"
    fi
  done
  log_success "All dependencies available"

  for repo in terraform-workspaces-deploy terraform-sec01-deploy terraform-build01-deploy terraform-agent01-deploy; do
    if [[ ! -d "${WORKSPACE}/${repo}" ]]; then
      error_exit "Terraform repo not found: ${WORKSPACE}/${repo}"
    fi
  done
  log_success "Terraform repos present"

  log_info "Testing Proxmox API connectivity..."
  if ! curl -s -k -u "${PROXMOX_USER}:${PROXMOX_PASSWORD}" \
    "${PROXMOX_URL}/api2/json/nodes" > /dev/null 2>&1; then
    error_exit "Cannot reach Proxmox API at ${PROXMOX_URL}"
  fi
  log_success "Proxmox API reachable"

  mkdir -p "${STATE_DIR}"
}

# ----------------------------------------------------------------------------
# Shared helpers
# ----------------------------------------------------------------------------
wait_for_ssh() {
  local host="$1"
  local label="$2"
  log_info "Waiting for ${label} (${host}) SSH accessibility (max 300s)..."
  local retries=30
  while ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "${SSH_KEY_FILE}" "${CI_USER}@${host}" /bin/true 2>/dev/null; do
    retries=$((retries - 1))
    if [[ ${retries} -le 0 ]]; then
      error_exit "${label} SSH unreachable after 300 seconds"
    fi
    sleep 10
  done
  log_success "${label} SSH accessible"
}

# Reads a Terraform output value (raw string) from a given repo directory.
tf_output() {
  local repo_dir="$1"
  local output_name="$2"
  terraform -chdir="${repo_dir}" output -raw "${output_name}"
}

##############################################################################
# PRE-PHASE: TFC workspace lifecycle (sec01, docker01, agent01)
##############################################################################

# Creates the per-host TFC workspaces (sec01, docker01, agent01) via
# terraform-workspaces-deploy, BEFORE any per-host repo tries to use one of
# those workspaces as its own `cloud {}` backend (see terraform-sec01-deploy,
# terraform-build01-deploy, terraform-agent01-deploy main.tf). This breaks the
# "a workspace needs a workspace to create it" cycle: this apply runs with
# local state (or from within the pre-created `bootstrap` TFC workspace), and
# only afterwards do the per-host applies initialize against a TFC backend
# that's actually there.
ensure_tfc_workspaces() {
  log_info "=== PRE-PHASE: Ensure TFC workspaces (sec01, docker01, agent01) ==="
  local repo="${WORKSPACE}/terraform-workspaces-deploy"

  terraform -chdir="${repo}" init -input=false
  terraform -chdir="${repo}" apply -auto-approve \
    || error_exit "Terraform apply failed for terraform-workspaces-deploy"

  log_success "TFC workspaces ensured (sec01, docker01, agent01)"
}

##############################################################################
# PHASE 3: Security Core (sec01)
##############################################################################

phase3_provision_sec01() {
  log_info "=== PHASE 3a: Provision sec01 (Terraform) ==="
  local repo="${WORKSPACE}/terraform-sec01-deploy"

  terraform -chdir="${repo}" init -input=false
  terraform -chdir="${repo}" apply -auto-approve \
    -var="proxmox_api_url=${PROXMOX_URL}/api2/json" \
    -var="proxmox_user=${PROXMOX_USER}" \
    -var="proxmox_password=${PROXMOX_PASSWORD}" \
    -var="ssh_public_keys=[\"$(cat "${SSH_KEY_FILE}.pub")\"]" \
    || error_exit "Terraform apply failed for sec01"

  SEC01_IP="$(tf_output "${repo}" sec01_ipv4_address | cut -d/ -f1)"
  log_success "sec01 provisioned (IP: ${SEC01_IP})"

  wait_for_ssh "${SEC01_IP}" "sec01"
}

phase3_run_orchestration() {
  log_info "=== PHASE 3b: Run phase-3-orchestrate.yml (step-ca, Vault, secret seeding) ==="
  log_warn "This step includes an interactive, blocking operator gate (Vault unseal-key backup)."

  ansible-playbook "${BOOTSTRAP_DIR}/playbooks/phase-3-orchestrate.yml" \
    -e "sec01_ip=${SEC01_IP}" \
    -e "ansible_ssh_private_key_file=${SSH_KEY_FILE}" \
    -e "ansible_user=${CI_USER}" \
    -e "proxmox_token=${PROXMOX_PASSWORD}" \
    -e "terraform_cloud_token=${TFC_TOKEN}" \
    -e "step_ca_provisioner_password=${STEP_CA_PROVISIONER_PASSWORD}" \
    || error_exit "Phase 3 orchestration playbook failed"

  log_success "Phase 3 orchestration complete (sec01: step-ca + Vault unsealed + secrets seeded)"
}

##############################################################################
# PHASE 4: CI Core (docker01, provisioned from terraform-build01-deploy)
##############################################################################

phase4_provision_docker01() {
  log_info "=== PHASE 4a: Provision docker01 (Terraform) ==="
  local repo="${WORKSPACE}/terraform-build01-deploy"

  terraform -chdir="${repo}" init -input=false
  terraform -chdir="${repo}" apply -auto-approve \
    -var="proxmox_api_url=${PROXMOX_URL}/api2/json" \
    -var="proxmox_user=${PROXMOX_USER}" \
    -var="proxmox_password=${PROXMOX_PASSWORD}" \
    -var="ssh_public_keys=[\"$(cat "${SSH_KEY_FILE}.pub")\"]" \
    || error_exit "Terraform apply failed for docker01"

  DOCKER01_IP="$(tf_output "${repo}" docker01_ipv4_address | cut -d/ -f1)"
  log_success "docker01 provisioned (IP: ${DOCKER01_IP})"

  wait_for_ssh "${DOCKER01_IP}" "docker01"
}

phase4_run_orchestration() {
  log_info "=== PHASE 4b: Run phase-4-orchestrate.yml (Jenkins + Vault AppRole wiring) ==="

  ansible-playbook "${BOOTSTRAP_DIR}/playbooks/phase-4-orchestrate.yml" \
    -e "sec01_ip=${SEC01_IP}" \
    -e "docker01_ip=${DOCKER01_IP}" \
    -e "ansible_ssh_private_key_file=${SSH_KEY_FILE}" \
    -e "ansible_user=${CI_USER}" \
    || error_exit "Phase 4 orchestration playbook failed"

  log_success "Phase 4 orchestration complete (docker01: Jenkins online, AppRole wired)"
}

##############################################################################
# PHASE 5: Build Capacity (agent01 LXC)
##############################################################################

phase5_provision_agent01() {
  log_info "=== PHASE 5a: Provision agent01 (Terraform, LXC) ==="
  local repo="${WORKSPACE}/terraform-agent01-deploy"

  terraform -chdir="${repo}" init -input=false
  terraform -chdir="${repo}" apply -auto-approve \
    -var="proxmox_api_url=${PROXMOX_URL}/api2/json" \
    -var="proxmox_user=${PROXMOX_USER}" \
    -var="proxmox_password=${PROXMOX_PASSWORD}" \
    -var="ssh_public_keys=[\"$(cat "${SSH_KEY_FILE}.pub")\"]" \
    || error_exit "Terraform apply failed for agent01"

  AGENT01_IP="$(tf_output "${repo}" agent01_ipv4_address)"
  log_success "agent01 LXC provisioned (IP: ${AGENT01_IP})"

  wait_for_ssh "${AGENT01_IP}" "agent01"
}

phase5_run_orchestration() {
  log_info "=== PHASE 5b: Run phase-5-orchestrate.yml (Jenkins agent, Vault agent, toolchain) ==="

  ansible-playbook "${BOOTSTRAP_DIR}/playbooks/phase-5-orchestrate.yml" \
    -e "sec01_ip=${SEC01_IP}" \
    -e "docker01_ip=${DOCKER01_IP}" \
    -e "agent01_ip=${AGENT01_IP}" \
    -e "ansible_ssh_private_key_file=${SSH_KEY_FILE}" \
    -e "ansible_user=${CI_USER}" \
    || error_exit "Phase 5 orchestration playbook failed"

  log_success "Phase 5 orchestration complete (agent01: Jenkins agent + Vault agent + toolchain ready)"
}

##############################################################################
# MAIN EXECUTION
##############################################################################

run_phase3() {
  log_info ""
  log_info "========== PHASE 3: Security Core (sec01) =========="
  run_step phase3_provision_sec01 phase3_provision_sec01
  run_step phase3_run_orchestration phase3_run_orchestration
  log_success "PHASE 3 COMPLETE"
}

run_phase4() {
  log_info ""
  log_info "========== PHASE 4: CI Core (docker01) =========="
  run_step phase4_provision_docker01 phase4_provision_docker01
  run_step phase4_run_orchestration phase4_run_orchestration
  log_success "PHASE 4 COMPLETE"
}

run_phase5() {
  log_info ""
  log_info "========== PHASE 5: Build Capacity (agent01) =========="
  run_step phase5_provision_agent01 phase5_provision_agent01
  run_step phase5_run_orchestration phase5_run_orchestration
  log_success "PHASE 5 COMPLETE"
}

main() {
  log_info "========== Vernify Bootstrap Script: Phases 3-5 =========="
  log_info "Start time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  parse_args "$@"
  validate_environment

  run_step ensure_tfc_workspaces ensure_tfc_workspaces

  case "${ONLY_PHASE}" in
    3) run_phase3 ;;
    4) run_phase4 ;;
    5) run_phase5 ;;
    "")
      run_phase3
      run_phase4
      run_phase5
      ;;
    *)
      error_exit "Invalid --only-phase value: ${ONLY_PHASE} (must be 3, 4, or 5)"
      ;;
  esac

  log_info ""
  log_info "========== BOOTSTRAP COMPLETE =========="
  log_success "All requested phases completed successfully!"
  echo ""
  echo "Vernify infrastructure status:"
  echo "  - sec01   (${SEC01_IP}):   step-ca + Vault (security core)"
  echo "  - docker01 (${DOCKER01_IP}): Jenkins container host (CI core)"
  echo "  - agent01 (${AGENT01_IP}): LXC build agent + Vault agent + toolchain"
  echo ""
  echo "Next steps:"
  echo "  1. Verify Vault health: curl -k \${VAULT_ADDR}/v1/sys/health"
  echo "  2. Access Jenkins: https://docker01.vernify.internal:8443"
  echo "  3. Confirm unseal keys are backed up externally (operator responsibility, not in Vault/git)"
  echo "  4. Archive and retire this bootstrap container (see RUNBOOK.md)"
  echo ""
  echo "End time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}

main "$@"
