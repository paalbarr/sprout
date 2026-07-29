# Changelog

All notable changes to this project will be documented in this file.

## [TODO]
- Modules for configuring Frontier AI models
- GIT for OpenClaw update

## [0.8.1] - 2026-07-29

### Added

- ASCII logo in main scripts including version and status release
- Validation of minimal requeriments before start
- Native Ollama+Tinyllama support
- Modules support for extensibility
- Git-based Garden module system: modules are published in a git repository
  and resolved, downloaded, and installed with their full dependency graph
- Two-tier CLI: a single `./sprout` entry point at the project root, so no
  command ever requires entering the stack directory
- New commands: `token` (show/regenerate the gateway token), `auth`
  (renamed from `approve-device`), `send` (non-interactive passthrough to
  `openclaw onboard`), `help` (local command reference, with an `-o` option
  for extended online documentation)
- Per-module install logs, kept at `state/logs/<module>.log` and
  overwritten on every attempt
- Quick-access shortcuts (`./workspace`, `./agents`, `./conf/openclaw.json`)
  next to `./sprout`

### Changed

- Improved Docker networking
- Improved "Next steps" guides text
- Renamed all containers to a `sprout-*` naming scheme (previously `openclaw-*`)
- Module `compose` files are now normalized automatically regardless of
  indentation style or file extension

### Fixed

- Fixed dependency-chain installs silently skipping every module after the
  first one, caused by a stdin conflict in the install loop

---

## [0.7] - 2026-07-27

### Added

- Interactive KEY entry for Tailscale
- Automatic TOKEN creation for Openclaw
- Installation of Ollama+Tinyllama module in embedded format

### Changed

Nothing

### Fixed

- Validating the output of commands sent to Docker
- Validating the output of commands sent to Openclaw

---

## [0.6] - 2026-07-23

### Added

- First public alpha release
- Automatic OpenClaw deployment
- Docker Compose generation
- ARM64 support
- x86_64 support
- README, ARCHITECTURE and HOWTO documentation

### Changed

- Improved OpenClaw configuration

### Fixed

- Gateway startup issues
- Tailscale Serve configuration