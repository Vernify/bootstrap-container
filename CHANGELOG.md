# CHANGELOG

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.0] — 2026-06-07

### Added
- Initial bootstrap container with pinned `packer 1.11.2`, `terraform 1.9.8`,
  `vault 1.17.5`, `step 0.27.4`, `ansible-core 2.17.*`, and `jq`.
- `entrypoint.sh` — interactive prompting for any missing required secrets;
  SSH key materialisation from `BOOTSTRAP_SSH_PRIVATE_KEY_B64` or a mounted
  secret file; ssh-agent setup; toolchain version banner.
- `requirements.yml` — pinned `blueprints.*` collection refs for all
  `iac-foundry` collections consumed during Phases 1–5.
- `docker-compose.yml` — convenience wrapper; passes all bootstrap env vars
  through; mounts SSH key and a persistent `/workspace` volume.
- `.env.example` — documented secret template; safe to commit (no real values).
- `README.md`, `CODEOWNERS`, `CHANGELOG.md`.
- `.gitignore` — blocks `.env`, `*.env`, SSH keys, and common editor artefacts.
