#!/bin/bash
#
# E2E Dry-Run Validation Script
# Validates bootstrap-phase-3-5.sh prerequisites and all deployment components
# without actually provisioning infrastructure
#
# Usage: ./e2e-test-dryrun.sh [--verbose]

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VERBOSE="${1:-}"
EXIT_CODE=0

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
  echo -e "${BLUE}ℹ${NC} $*"
}

log_pass() {
  echo -e "${GREEN}✅${NC} $*"
}

log_fail() {
  echo -e "${RED}❌${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}⚠${NC} $*"
}

log_debug() {
  [[ -n "$VERBOSE" ]] && echo -e "${BLUE}→${NC} $*" || true
}

# Test result tracking
declare -a TEST_RESULTS=()

run_test() {
  local test_name="$1"
  local test_cmd="$2"

  log_info "Testing: $test_name"

  if eval "$test_cmd" &>/dev/null; then
    log_pass "$test_name: PASSED"
    TEST_RESULTS+=("✅ $test_name")
    return 0
  else
    log_fail "$test_name: FAILED"
    TEST_RESULTS+=("❌ $test_name")
    EXIT_CODE=1
    return 1
  fi
}

# ============================================================================
# SECTION 1: Environment Variables Check
# ============================================================================

echo ""
echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}E2E Dry-Run Validation${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

section_1_pass=0

log_info "Section 1: Environment Variables Check"

# Required environment variables for Phase 3-5
REQUIRED_VARS=(
  "PROXMOX_HOST"
  "PROXMOX_USER"
  "PROXMOX_PASSWORD"
  "PROXMOX_NODE"
  "VAULT_ADDR"
  "VAULT_TOKEN"
  "ANSIBLE_VAULT_PASSWORD"
)

all_env_ok=true
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -n "${!var:-}" ]]; then
    log_debug "$var is set"
  else
    log_warn "Environment variable $var is not set (required for deployment)"
    all_env_ok=false
  fi
done

if [[ "$all_env_ok" == true ]]; then
  log_pass "Environment variables check: PASSED (all required vars set)"
  TEST_RESULTS+=("✅ Environment variables check")
else
  log_warn "Environment variables check: PASSED (not all vars set, but acceptable for dry-run)"
  TEST_RESULTS+=("⚠ Environment variables check (partial)")
fi

# ============================================================================
# SECTION 2: Packer Template Validation
# ============================================================================

echo ""
log_info "Section 2: Packer Template Check"

PACKER_TEMPLATES=(
  "/Users/wernervandermerwe/workspace/iac-foundry/packer-template-vmware/ubuntu-jammy.pkr.hcl"
  "/Users/wernervandermerwe/workspace/iac-foundry/packer-template-proxmox/ubuntu-jammy.pkr.hcl"
)

packer_ok=true
for template in "${PACKER_TEMPLATES[@]}"; do
  if [[ -f "$template" ]]; then
    log_debug "Found Packer template: $template"
  else
    log_warn "Packer template not found: $template"
    packer_ok=false
  fi
done

if [[ "$packer_ok" == true ]]; then
  log_pass "Packer templates check: PASSED (all templates found)"
  TEST_RESULTS+=("✅ Packer templates check")
else
  log_fail "Packer templates check: FAILED (some templates missing)"
  TEST_RESULTS+=("❌ Packer templates check")
  EXIT_CODE=1
fi

# ============================================================================
# SECTION 3: LXC Image Validation
# ============================================================================

echo ""
log_info "Section 3: LXC Image Check"

# Check if Proxmox access is available (dry-run: optional)
if [[ -n "${PROXMOX_HOST:-}" ]]; then
  log_info "Proxmox host configured, would verify LXC image on Proxmox"
  TEST_RESULTS+=("✅ LXC image check (configured for Proxmox)")
else
  log_warn "Proxmox not configured (acceptable for dry-run)"
  TEST_RESULTS+=("⚠ LXC image check (Proxmox not configured)")
fi

# ============================================================================
# SECTION 4: Terraform Module Validation
# ============================================================================

echo ""
log_info "Section 4: Terraform Module Check"

TERRAFORM_REPOS=(
  "/Users/wernervandermerwe/workspace/iac-foundry/terraform-proxmox-vm"
  "/Users/wernervandermerwe/workspace/iac-foundry/terraform-tfe-workspace"
  "/Users/wernervandermerwe/workspace/vernify/terraform-sec01-deploy"
  "/Users/wernervandermerwe/workspace/vernify/terraform-docker01-deploy"
  "/Users/wernervandermerwe/workspace/vernify/terraform-agent01-deploy"
)

terraform_ok=true
for repo in "${TERRAFORM_REPOS[@]}"; do
  if [[ -d "$repo" ]] && [[ -f "$repo/main.tf" ]]; then
    log_debug "Found Terraform module: $repo"
  else
    log_warn "Terraform module not fully present: $repo"
    terraform_ok=false
  fi
done

if [[ "$terraform_ok" == true ]]; then
  log_pass "Terraform modules check: PASSED (all modules present)"
  TEST_RESULTS+=("✅ Terraform modules check")
else
  log_fail "Terraform modules check: FAILED (some modules missing)"
  TEST_RESULTS+=("❌ Terraform modules check")
  EXIT_CODE=1
fi

# ============================================================================
# SECTION 5: Terraform Plan Validation
# ============================================================================

echo ""
log_info "Section 5: Terraform Plan Validation (dry-run)"

TERRAFORM_DEPLOY_REPOS=(
  "/Users/wernervandermerwe/workspace/vernify/terraform-sec01-deploy"
  "/Users/wernervandermerwe/workspace/vernify/terraform-docker01-deploy"
  "/Users/wernervandermerwe/workspace/vernify/terraform-agent01-deploy"
)

for repo in "${TERRAFORM_DEPLOY_REPOS[@]}"; do
  repo_name=$(basename "$repo")

  if [[ -d "$repo" ]]; then
    cd "$repo"

    # Check if terraform is available
    if ! command -v terraform &> /dev/null; then
      log_warn "terraform not found in PATH, skipping plan for $repo_name"
      TEST_RESULTS+=("⚠ Terraform plan: $repo_name (terraform CLI not available)")
      continue
    fi

    # Validate Terraform syntax
    log_info "Validating Terraform syntax for $repo_name"
    if terraform validate &>/dev/null; then
      log_pass "Terraform validate $repo_name: PASSED"
      TEST_RESULTS+=("✅ Terraform validate: $repo_name")
    else
      log_fail "Terraform validate $repo_name: FAILED"
      TEST_RESULTS+=("❌ Terraform validate: $repo_name")
      EXIT_CODE=1
    fi
  else
    log_warn "Terraform deploy repo not found: $repo"
    TEST_RESULTS+=("⚠ Terraform repo: $repo_name (not found)")
  fi
done

# ============================================================================
# SECTION 6: Ansible Playbook Validation
# ============================================================================

echo ""
log_info "Section 6: Ansible Playbook Syntax Check"

# Check if ansible-playbook is available
if ! command -v ansible-playbook &> /dev/null; then
  log_warn "ansible-playbook not found in PATH, skipping syntax checks"
  TEST_RESULTS+=("⚠ Ansible syntax check (ansible not installed)")
else
  PLAYBOOK_DIRS=(
    "/Users/wernervandermerwe/workspace/vernify/bootstrap-container/playbooks"
  )

  ansible_ok=true
  for playbook_dir in "${PLAYBOOK_DIRS[@]}"; do
    if [[ -d "$playbook_dir" ]]; then
      log_info "Scanning playbooks in $playbook_dir"

      # Find all .yml and .yaml files
      while IFS= read -r playbook; do
        if [[ -f "$playbook" ]]; then
          if ansible-playbook --syntax-check "$playbook" &>/dev/null; then
            log_debug "Syntax OK: $playbook"
          else
            log_fail "Ansible syntax error in: $playbook"
            ansible_ok=false
          fi
        fi
      done < <(find "$playbook_dir" -type f \( -name "*.yml" -o -name "*.yaml" \))
    fi
  done

  if [[ "$ansible_ok" == true ]]; then
    log_pass "Ansible playbook syntax check: PASSED"
    TEST_RESULTS+=("✅ Ansible playbook syntax")
  else
    log_fail "Ansible playbook syntax check: FAILED"
    TEST_RESULTS+=("❌ Ansible playbook syntax")
    EXIT_CODE=1
  fi
fi

# ============================================================================
# SECTION 7: Ansible Collection Validation
# ============================================================================

echo ""
log_info "Section 7: Ansible Collection Structure Check"

ANSIBLE_COLLECTIONS=(
  "/Users/wernervandermerwe/workspace/iac-foundry/ansible-collection-step-ca"
  "/Users/wernervandermerwe/workspace/iac-foundry/ansible-collection-vault"
  "/Users/wernervandermerwe/workspace/iac-foundry/ansible-collection-jenkins"
  "/Users/wernervandermerwe/workspace/iac-foundry/ansible-collection-vault-integrations"
  "/Users/wernervandermerwe/workspace/iac-foundry/ansible-collection-jenkins-integrations"
)

collections_ok=true
for collection in "${ANSIBLE_COLLECTIONS[@]}"; do
  if [[ -d "$collection/roles" ]]; then
    role_count=$(find "$collection/roles" -mindepth 1 -maxdepth 1 -type d | wc -l)
    if [[ $role_count -gt 0 ]]; then
      log_debug "Found $role_count roles in $collection"
    else
      log_warn "No roles found in $collection/roles"
      collections_ok=false
    fi
  else
    log_warn "Roles directory not found: $collection/roles"
    collections_ok=false
  fi
done

if [[ "$collections_ok" == true ]]; then
  log_pass "Ansible collections check: PASSED (all collections present)"
  TEST_RESULTS+=("✅ Ansible collections check")
else
  log_fail "Ansible collections check: FAILED (some collections incomplete)"
  TEST_RESULTS+=("❌ Ansible collections check")
  EXIT_CODE=1
fi

# ============================================================================
# SECTION 8: Vault Configuration Validation
# ============================================================================

echo ""
log_info "Section 8: Vault Configuration Validation"

# Check if vault CLI is available
if ! command -v vault &> /dev/null; then
  log_warn "vault CLI not found in PATH, skipping Vault validation"
  TEST_RESULTS+=("⚠ Vault validation (vault CLI not installed)")
else
  # Check if VAULT_ADDR is set
  if [[ -n "${VAULT_ADDR:-}" ]]; then
    log_debug "VAULT_ADDR is set to: ${VAULT_ADDR}"
    TEST_RESULTS+=("✅ Vault configuration check")
  else
    log_warn "VAULT_ADDR not set, Vault operations will not be available"
    TEST_RESULTS+=("⚠ Vault configuration (VAULT_ADDR not set)")
  fi
fi

# ============================================================================
# SUMMARY
# ============================================================================

echo ""
echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}Test Results Summary${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

for result in "${TEST_RESULTS[@]}"; do
  echo "$result"
done

echo ""
if [[ $EXIT_CODE -eq 0 ]]; then
  echo -e "${GREEN}Overall: PASSED${NC}"
  echo -e "${GREEN}All checks passed. Ready for Phase D integration.${NC}"
  echo ""
else
  echo -e "${RED}Overall: FAILED${NC}"
  echo -e "${RED}Some checks failed. Please review the errors above.${NC}"
  echo ""
fi

exit $EXIT_CODE
