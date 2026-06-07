# Vernify Bootstrap Container — Runbook

> **This document guides you through Phase 0 of the Vernify homelab greenfield bootstrap.**
>
> Follow this runbook to prepare the bootstrap container with your secrets, then use it to execute
> Phases 1–5. Retire the container at the end of Phase 5 once Jenkins and Vault own automation.

---

## Phase 0 — Preparation

### Prerequisites

- **Docker** and **Docker Compose** installed on your workstation
- **SSH keypair** for first-boot access to VMs (e.g., `~/.ssh/id_vernify_bootstrap`)
- **Proxmox** running and accessible (VM host for all future infrastructure)
- **GitHub organization** (Vernify) to pull IaC repos
- **Terraform Cloud** account and a dedicated Vernify team token
- **Secrets** ready (Proxmox password, TFC token, GitHub PAT, step-ca provisioner password)

### Step 1: Clone this repo

```bash
git clone https://github.com/Vernify/bootstrap-container.git
cd bootstrap-container
```

### Step 2: Create your `.env` file

```bash
cp .env.example .env
$EDITOR .env
```

Fill in **all** required values:

| Variable | Example | Notes |
|---|---|---|
| `PROXMOX_URL` | `https://pve08.vernify.com:8006` | The Proxmox web UI URL |
| `PROXMOX_USER` | `root@pam` | Proxmox username |
| `PROXMOX_PASSWORD` | (your password) | Proxmox password — **never commit this** |
| `TFC_TOKEN` | (your token) | Terraform Cloud team token — **secret** |
| `GIT_PAT` | (your token) | GitHub PAT for the Vernify org — **secret** |
| `STEP_CA_PROVISIONER_PASSWORD` | (your password) | step-ca provisioner password (used Phase 3) — **secret** |

> ⚠️  **Security:** Never commit `.env` to version control. The `.gitignore` blocks it.
> Consider storing `.env` in a secure location (e.g., 1Password, Vault, encrypted USB).

### Step 3: Build the container

```bash
docker compose build
```

This bakes all tools (packer, terraform, ansible, vault, step, jq) and pre-installs the
`blueprints.*` collections. Build takes 1–2 minutes.

### Step 4: Verify the setup

```bash
source .env
docker compose run --rm bootstrap

# Inside the container, confirm all tools are available:
ansible --version
packer version
terraform version
vault version
step version
jq --version

# List the blueprints.* collections:
ansible-galaxy collection list | grep blueprints

# Exit the container
exit
```

---

## Phase 1 — Packer base template

> **What:** Build the Proxmox VM template (ubuntu-base + container-host variants).
>
> **Uses:** Packer, Proxmox API, `blueprints.packer` (stub — not yet implemented).
>
> **Produces:** A reusable VM template in Proxmox that every later phase clones from.

### Prerequisites for Phase 1

- Bootstrap container is built and `.env` is filled in
- Proxmox is running and you can access the web UI
- A Proxmox datastore (e.g., `local`) where the template will be stored

### Step 1: Prepare the Packer template

The Packer HCL is located in `~/workspace/iac-foundry/packer-template-proxmox/`.
Currently it is a **stub** — you must author the actual template.

Inside the bootstrap container:

```bash
source .env
docker compose run --rm bootstrap

# Inside the container:
cd /workspace/iac-foundry/packer-template-proxmox

# Review the existing structure
ls -la

# Author the ubuntu-base.pkr.hcl template (see roadmap for guidance)
# This should use the blueprints.packer role and produce a Proxmox template.
```

**Reference:** Check the VMware packer template for patterns:
`~/workspace/iac-foundry/packer-template-vmware/`

### Step 2: Initialize and validate

```bash
# Inside the container:
packer init proxmox/
packer validate proxmox/ubuntu-base.pkr.hcl
```

### Step 3: Build the template

```bash
# Inside the container:
packer build proxmox/ubuntu-base.pkr.hcl

# Watch the build progress in the Proxmox web UI.
# Once complete, the template will appear in Proxmox under:
#   Datacenter → Nodes → [node] → Qemu → [template-name]
```

### Step 4: Verify in Proxmox

- Log into Proxmox web UI
- Navigate to **Datacenter** → **Nodes** → your node
- Look for the new VM template under **Qemu**
- Verify it has the correct size and resources

---

## Phase 2 — TFC workspaces + VM lifecycle

> **What:** Create Terraform Cloud workspaces and a Proxmox VM module so we can declaratively
> provision VMs.
>
> **Uses:** Terraform, TFC API, `blueprints.terraform` (not yet implemented).
>
> **Produces:** TFC workspaces for Vernify + a reusable Proxmox VM module.

### Prerequisites for Phase 2

- Phase 1 Packer template is built and present in Proxmox
- Terraform Cloud team token is in `.env`
- You have write access to the Vernify TFC organization

### Step 1: Create Terraform modules

The Terraform code is in `~/workspace/vernify/platform-infrastructure/` (or similar — create if needed).

Inside the bootstrap container:

```bash
source .env
docker compose run --rm bootstrap

cd /workspace/vernify

# Create the terraform directory structure
mkdir -p terraform/modules/proxmox-vm
mkdir -p terraform/workspaces/main

# Author the TFC workspace module and the Proxmox VM module
# Reference iac-foundry terraform examples
```

### Step 2: Initialize Terraform

```bash
# Inside the container:
cd /workspace/vernify/terraform
terraform init

# Terraform will prompt for TFC organization/workspace names
# Use org: Vernify, workspace: main
```

### Step 3: Plan and apply

```bash
# Inside the container:
terraform plan

# Review the plan (should create workspaces and variables)
terraform apply
```

### Step 4: Verify in TFC

- Log into https://app.terraform.io/app/Vernify
- Verify new workspaces are created
- Verify variable sets are populated with Proxmox token, etc.

---

## Phase 3 — Security core (sec01: step-ca → Vault)

> **What:** Provision `sec01`, install step-ca and Vault, unseal Vault, and hand off secrets
> into Vault. **This is the critical secret hand-off** — after this, all downstream secrets come
> from Vault, not the CLI.
>
> **Uses:** Terraform (to provision sec01), Ansible (`blueprints.vault`, `blueprints.common`),
> the `vault` CLI, the `step` CLI.
>
> **Produces:** A running Vault and step-ca; all Phase 0 secrets migrated into Vault; unseal material
> stored securely outside the container.

### Prerequisites for Phase 3

- Phase 2 TFC workspaces are created
- Terraform has provisioned `sec01` VM (from the Phase 1 template)
- SSH access to `sec01` is working
- step-ca provisioner password is in `.env`

### Step 1: Provision sec01 via Terraform

Inside the bootstrap container:

```bash
source .env
docker compose run --rm bootstrap

cd /workspace/vernify/terraform/workspaces/main

# Provision sec01 (and configure networking)
terraform apply
```

### Step 2: Install step-ca on sec01

Use Ansible to run `blueprints.packer` (or manual steps) to install step-ca as the PKI trust anchor.

```bash
# Inside the container:
cd /workspace/vernify

# Create playbook to install step-ca
cat > playbook-step-ca.yml << 'EOF'
---
- hosts: sec01
  roles:
    - blueprints.packer.step_ca_install
  vars:
    step_ca_provisioner_password: "{{ lookup('env', 'STEP_CA_PROVISIONER_PASSWORD') }}"
EOF

# Run the playbook
ansible-playbook playbook-step-ca.yml
```

### Step 3: Install Vault on sec01

Once step-ca is running, deploy Vault with TLS issued by step-ca:

```bash
# Inside the container:
cat > playbook-vault.yml << 'EOF'
---
- hosts: sec01
  roles:
    - blueprints.common.service_user
    - blueprints.common.tls_material
    - blueprints.vault.container_server
  vars:
    vault_tls_cert_source: "step_ca"  # TLS from step-ca
EOF

ansible-playbook playbook-vault.yml
```

### Step 4: Unseal Vault (external operation)

Init and unseal Vault — **this is manual, one-time**:

```bash
# Outside the container (on your workstation):
export VAULT_ADDR="https://sec01.vernify.com:8200"

vault operator init -key-shares=5 -key-threshold=3 \
  > /path/to/secure/storage/vault-init.txt

# Store unseal keys and root token in a secure location (HSM, Vault, 1Password, etc.)
# Do NOT store them in the container or in git.
```

### Step 5: Seed Vault with bootstrap secrets

Once Vault is unsealed, use the bootstrap container to seed all Phase 0 secrets:

```bash
# Inside the container:
export VAULT_ADDR="https://sec01.vernify.com:8200"
export VAULT_TOKEN="<root-token-from-init>"

# Seed Proxmox credentials
vault kv put secret/proxmox/bootstrap \
  url="$PROXMOX_URL" \
  user="$PROXMOX_USER" \
  password="$PROXMOX_PASSWORD"

# Seed TFC token
vault kv put secret/terraform/tfc \
  token="$TFC_TOKEN"

# Seed GitHub PAT
vault kv put secret/github/vernify \
  pat="$GIT_PAT"

# Seed step-ca provisioner password
vault kv put secret/step-ca \
  provisioner_password="$STEP_CA_PROVISIONER_PASSWORD"

# Seed Jenkins admin token (placeholder for Phase 4)
vault kv put secret/jenkins/admin \
  token="<jenkins-admin-token-from-phase-4>"
```

### Step 6: Deploy vault-agent on consumer hosts

Downstream hosts use `vault-agent` to pull secrets and refresh TLS certs:

```bash
# Inside the container:
cat > playbook-vault-agent.yml << 'EOF'
---
- hosts: all
  roles:
    - blueprints.vault.agent_systemd
  vars:
    vault_addr: "{{ lookup('env', 'VAULT_ADDR') }}"
EOF

ansible-playbook playbook-vault-agent.yml
```

> **After Phase 3:** Downstream phases no longer use CLI secrets. All secret retrieval is via
> `community.hashi_vault` lookups from Vault.

---

## Phase 4 — CI core (build01: Jenkins)

> **What:** Provision `build01`, deploy Jenkins as a container, configure AppRole auth with Vault,
> seed pipelines.
>
> **Uses:** Terraform (to provision build01), Ansible (`blueprints.jenkins.container_server`),
> `blueprints.jenkins_integrations.vault_auth`.
>
> **Produces:** A running Jenkins that can pull secrets from Vault and execute IaC pipelines.

### Prerequisites for Phase 4

- Phase 3 is complete: Vault is running with all secrets seeded
- Terraform has provisioned `build01` VM
- SSH access to `build01` is working

### Step 1: Provision build01 via Terraform

```bash
# Inside the bootstrap container:
source .env
docker compose run --rm bootstrap

export VAULT_ADDR="https://sec01.vernify.com:8200"
export VAULT_TOKEN="<operator-token>"

cd /workspace/vernify/terraform/workspaces/main

terraform apply  # Provisions build01
```

### Step 2: Deploy Jenkins container

```bash
# Inside the container:
cat > playbook-jenkins.yml << 'EOF'
---
- hosts: build01
  roles:
    - blueprints.jenkins.container_server
    - blueprints.jenkins_integrations.vault_auth  # AppRole for Vault
EOF

ansible-playbook playbook-jenkins.yml
```

### Step 3: Configure Jenkins pipelines

Seed Jenkins with Job DSL pipelines that orchestrate:
- Packer builds (Phase 1)
- Terraform applies (Phase 2)
- Ansible runs (Phase 3+)

```bash
# Inside the container:
cat > playbook-jenkins-pipelines.yml << 'EOF'
---
- hosts: build01
  roles:
    - blueprints.jenkins.job_dsl
  vars:
    job_dsl_git_repo: "https://github.com/Vernify/jenkins-job-definitions"
EOF

ansible-playbook playbook-jenkins-pipelines.yml
```

### Step 4: Verify Jenkins is running

- Access Jenkins at `https://build01.vernify.com:8080`
- Log in (credentials from Vault)
- Verify pipelines are seeded and ready to trigger

---

## Phase 5 — Build capacity (agent01: Jenkins agent)

> **What:** Provision `agent01`, deploy a Jenkins agent connected to build01, install the
> toolchain (packer, terraform, ansible). **After this phase, retire the bootstrap container.**
>
> **Uses:** Terraform (to provision agent01), Ansible (`blueprints.jenkins.agent`).
>
> **Produces:** A self-hosted Jenkins agent ready to execute pipelines. The homelab is now
> **self-hosting its IaC**.

### Prerequisites for Phase 5

- Phase 4 is complete: Jenkins is running on build01
- Terraform has provisioned `agent01` VM
- SSH access to `agent01` is working

### Step 1: Provision agent01 via Terraform

```bash
# Inside the bootstrap container:
source .env
docker compose run --rm bootstrap

export VAULT_ADDR="https://sec01.vernify.com:8200"
export VAULT_TOKEN="<operator-token>"

cd /workspace/vernify/terraform/workspaces/main

terraform apply  # Provisions agent01
```

### Step 2: Deploy Jenkins agent

```bash
# Inside the container:
cat > playbook-jenkins-agent.yml << 'EOF'
---
- hosts: agent01
  roles:
    - blueprints.jenkins.agent  # Systemd service connecting to build01
    - blueprints.common.service_user
EOF

ansible-playbook playbook-jenkins-agent.yml
```

### Step 3: Install toolchain on agent01

The agent needs packer, terraform, ansible preinstalled:

```bash
# Inside the container:
cat > playbook-agent-toolchain.yml << 'EOF'
---
- hosts: agent01
  tasks:
    - name: Install packer, terraform, ansible
      apt:
        name:
          - packer
          - terraform
          - ansible
        state: present
EOF

ansible-playbook playbook-agent-toolchain.yml
```

### Step 4: Verify agent is connected

- Access Jenkins at `https://build01.vernify.com:8080`
- Navigate to **Manage Jenkins** → **Nodes**
- Verify `agent01` appears and is **online**

### Step 5: Retire the bootstrap container

**You are done with Phase 0.**

The bootstrap container is no longer needed. From this point forward:

- **Secrets** are managed by Vault (never on the CLI again)
- **Automation** is managed by Jenkins pipelines (never run ad-hoc from the operator laptop)
- **Infrastructure** is declared in Terraform (never pet servers)

Archive the bootstrap container and your `.env` file in a secure location (encrypted USB, etc.)
for disaster recovery reference only.

```bash
# Outside the container:
# Save .env to secure backup
cp .env /path/to/secure/backup/.env.backup

# (Optionally) push any final changes to this repo
cd bootstrap-container
git add -A
git commit -m "feat: Phase 5 complete — bootstrap container retired"
git push
```

---

## Troubleshooting

### Q: "Checking required secrets" hangs at a prompt

**A:** The container is waiting for an interactive secret. Ensure all 6 secrets are either:
1. Set as environment variables in your shell before running `docker compose run`, or
2. Supplied in `.env` which you `source`d before running `docker compose run`

### Q: "Cannot stat /run/secrets/bootstrap_ssh_key"

**A:** You didn't mount an SSH key. Either:
1. Copy your SSH key to the location specified in `docker-compose.yml` (`~/.ssh/id_vernify_bootstrap`)
2. Set `BOOTSTRAP_SSH_PRIVATE_KEY_B64` env var with a base64-encoded key
3. Use agent forwarding (`ssh-add` your key, then run the container)

### Q: Ansible says "Host not reachable"

**A:** The newly provisioned VMs may take a few minutes to boot. Verify:
1. VMs appear in Proxmox web UI
2. They have IP addresses (check DHCP logs or Proxmox console)
3. SSH works: `ssh -i ~/.ssh/id_vernify_bootstrap root@<vm-ip>`

### Q: Terraform plan shows "No changes"

**A:** Either your infrastructure is already built, or the state is out of sync. Verify:
1. TFC workspaces exist and are linked to the correct state
2. Run `terraform refresh` to sync state with reality
3. Check TFC web UI for any pending or locked runs

### Q: Vault is sealed and I don't have unseal keys

**A:** You'll need to restore from backup or perform a full reset. **Always store unseal keys
separately from the cluster** (HSM, Vault DR, encrypted backup, etc.). This is a critical
operational procedure — reference Vault's disaster recovery docs.

---

## References

- [Vernify Greenfield Bootstrap Roadmap](https://github.com/Vernify/roadmap/blob/main/HOMELAB_GREENFIELD_BOOTSTRAP.md)
- [iac-foundry collections](https://github.com/iac-foundry)
- [Proxmox documentation](https://pve.proxmox.com/wiki/Main_Page)
- [HashiCorp Vault docs](https://www.vaultproject.io/docs)
- [Terraform Cloud docs](https://www.terraform.io/cloud-docs)
- [Jenkins documentation](https://www.jenkins.io/doc/)
