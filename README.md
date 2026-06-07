# Vernify Bootstrap Container

> **Phase 0** of the [Vernify homelab greenfield bootstrap](https://github.com/Vernify/roadmap).
> An ephemeral, self-contained control plane that carries the minimal toolchain and secrets
> needed to stand up the homelab from a bare Proxmox node to a fully self-hosted IaC platform.
> Retired at **Phase 5** once Jenkins and Vault assume responsibility for secrets and automation.

---

## Why this container exists

A greenfield platform is a chain of chicken-and-egg dependencies:

- You cannot pull secrets from **Vault** before Vault exists.
- You cannot issue internal **TLS** before **step-ca** exists.
- You cannot run automation as pipelines before **Jenkins** exists.
- You cannot clone **VMs** before a **Packer template** exists.

The bootstrap container breaks that cycle. Secrets are supplied once on the CLI, used only long
enough to birth the real control plane, then **handed off into Vault** and the container is
discarded.

---

## Baked toolchain

| Tool | Version (ARG) | Purpose |
|---|---|---|
| `ansible-core` | `2.17.*` | Runs `blueprints.*` roles against Vernify hosts |
| `blueprints.*` collections | `requirements.yml` | Reusable building blocks from `iac-foundry` |
| `packer` | `1.11.2` | Builds the Proxmox base VM template (Phase 1) |
| `terraform` | `1.9.8` | Manages TFC workspaces + VM lifecycle (Phase 2+) |
| `vault` (CLI) | `1.17.5` | Init/unseal + secret seeding (Phase 3) |
| `step` (CLI) | `0.27.4` | PKI root + provisioner setup on `sec01` (Phase 3) |
| `jq` | latest | JSON processing throughout |

Override any version at build time:
```bash
docker build \
  --build-arg PACKER_VERSION=1.11.3 \
  --build-arg TERRAFORM_VERSION=1.10.0 \
  -t vernify/bootstrap-container:local .
```

---

## Secrets

The container requires the following secrets.  Supply them via environment variables (sourced
from `.env`) or enter them interactively when the container starts — it will prompt for anything
that is missing.

| Variable | Description | Secret? |
|---|---|---|
| `PROXMOX_URL` | Proxmox web UI URL, e.g. `https://pve08.vernify.com:8006` | No |
| `PROXMOX_USER` | Proxmox username, e.g. `root@pam` | No |
| `PROXMOX_PASSWORD` | Proxmox password | **Yes** |
| `TFC_TOKEN` | Terraform Cloud team token | **Yes** |
| `GIT_PAT` | GitHub PAT (repo read, read:org) for the Vernify org | **Yes** |
| `STEP_CA_PROVISIONER_PASSWORD` | step-ca JWK/ACME provisioner password | **Yes** |
| `BOOTSTRAP_SSH_PRIVATE_KEY_B64` | Base64-encoded SSH private key (option A) | **Yes** |
| `VAULT_ADDR` | Vault address — blank until Phase 3 | No |
| `VAULT_TOKEN` | Vault root/operator token — blank until Phase 3 | **Yes** |

> **SSH key — two options.**
> Mount the key file (preferred for interactive use, see `docker-compose.yml`), or supply it
> as a base64-encoded env var (`BOOTSTRAP_SSH_PRIVATE_KEY_B64`).  Agent forwarding also works
> if neither option is configured.

---

## Quick start

**For interactive shell** (recommended for manual work):

```bash
# 1. Clone
git clone https://github.com/Vernify/bootstrap-container.git
cd bootstrap-container

# 2. Fill in secrets
cp .env.example .env
$EDITOR .env          # populate all required values (workspace path, proxmox, etc)

# 3. Build the image
docker compose build

# 4. Run with interactive shell
# Docker Compose automatically loads .env, so no need to source it
docker compose run -it --rm bootstrap
# You are now inside the container shell with /workspace mounted

# Confirm all tools are available:
ansible --version
packer version
terraform version
vault version
step version
jq --version

# Explore the workspace:
cd /workspace && ls -la

# Exit the container
exit
```

**For non-interactive use** (e.g. in CI/CD):

```bash
docker compose run --rm bootstrap ansible-playbook my-playbook.yml
# or
docker compose run --rm bootstrap packer build template.pkr.hcl
```

**For the full Phase 0–5 bootstrap workflow, see [RUNBOOK.md](RUNBOOK.md).**

---

## Repository layout

```
bootstrap-container/
├── Dockerfile            # Image definition — all pinned versions live here
├── entrypoint.sh         # Secret checks + interactive prompting + shell drop
├── requirements.yml      # blueprints.* collection refs (pinned to Git SHA/tag)
├── docker-compose.yml    # Convenience wrapper for interactive use
├── .env.example          # Secret template — copy, fill in, source before run
├── CODEOWNERS            # Code ownership
├── CHANGELOG.md          # Release history
└── README.md             # This file
```

---

## Lifecycle

```
Phase 0   → bootstrap container is the control plane
Phase 1   → Packer base template
Phase 2   → TFC workspaces + VM lifecycle
Phase 3   → sec01: step-ca → Vault; secrets hand-off OUT of this container
Phase 4   → build01: Jenkins
Phase 5   → agent01: Jenkins agent; RETIRE THIS CONTAINER
```

Once Phase 5 is complete, Jenkins pipelines and Vault manage all secrets and automation.
This container is no longer needed.

---

## Security notes

- **Never commit a filled-in `.env` file.**  The `.gitignore` blocks `*.env` and `.env`
  explicitly.
- Secrets passed via `--env-file` are visible to `docker inspect`.  Prefer Docker secrets
  (mounted at `/run/secrets/`) or short-lived env vars in a subshell where possible.
- The container runs as `root` — acceptable for a short-lived ephemeral operator tool on a
  trusted workstation, not appropriate for long-running services.

---

## Related repositories

| Repo | Purpose |
|---|---|
| [iac-foundry/ansible-collection-common](https://github.com/iac-foundry/ansible-collection-common) | `blueprints.common` |
| [iac-foundry/ansible-collection-vault](https://github.com/iac-foundry/ansible-collection-vault) | `blueprints.vault` |
| [iac-foundry/ansible-collection-jenkins](https://github.com/iac-foundry/ansible-collection-jenkins) | `blueprints.jenkins` |
| [iac-foundry/ansible-collection-graylog](https://github.com/iac-foundry/ansible-collection-graylog) | `blueprints.graylog` |
| [Vernify/roadmap](https://github.com/Vernify/roadmap) | Full greenfield bootstrap roadmap |

---

## License

MIT — see [LICENSE](LICENSE).
