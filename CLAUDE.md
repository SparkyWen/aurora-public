# CLAUDE.md

Guidance for AI coding agents working in this repository. Human contributors: see `CONTRIBUTING.md`, which
this file builds on.

Aurora is a self-hosted, multi-protocol, no-telemetry VPN: a Flutter app, the sing-box core, and a
one-command node installer. The core idea spans the repo:

```
install.sh -> aurora:// link -> ContractEditor -> contract -> ConfigCompiler -> sing-box JSON -> platform VPN layer
```

Read `docs/architecture.md` for the map, and `CONTRIBUTING.md` for the **hard constraints**. Violating one of
those is a bug. Read `docs/reliability-notes.md` before changing anything in the data path, connection logic
or platform service: most of the code that looks over-careful exists because of a failure documented there.

## Rules that are easy to break

- English only in code, comments, UI and docs.
- Never commit secrets, real server addresses, or personal identifiers. Use documentation addresses.
- After a data-path change, verify the **exit**, not just connectivity.
- `app/lib/cli/` and `app/bin/` must stay free of Flutter imports.
- Changing compiler output means updating `app/test/fixtures/expected-*.json` and re-validating with
  `sing-box check`.
- Do not run `dart format` across files you did not otherwise change: the sources are not format-clean.
- `install.sh` is one file, compatible with bash 3.2, and all logic stays inside functions.
- Run `install.sh` only through `deploy/test/*`, unless the user explicitly asks you to install a node. It
  changes system services and firewalls.

## Commands

See the test table in `CONTRIBUTING.md` and the build steps in `docs/building.md`.
