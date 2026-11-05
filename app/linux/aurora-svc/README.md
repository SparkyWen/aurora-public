# Linux packaging binaries

Before building the Linux desktop app, place these three files in this directory
(all are gitignored and not committed):

| File | Source |
|---|---|
| `sing-box` | the official release archive `sing-box-<version>-linux-amd64.tar.gz` |
| `aurora-svc` | `cd desktop/aurora-svc && GOOS=linux GOARCH=amd64 go build -o ../../app/linux/aurora-svc/aurora-svc ./...` |
| `aurora-cli` | `cd app && dart build cli -o build/cli && install -m 0755 build/cli/bundle/bin/aurora_cli linux/aurora-svc/aurora-cli` |

All three need `chmod +x`. If any is missing, CMake only prints a WARNING and
skips it: the build still succeeds but connecting is bound to fail, so CI asserts
that each one exists.

None of these files contains a contract. The app starts empty and you add a server
by importing an `aurora://` link; a private fork may embed a contract at
`app/assets/configs/aurora-contract.json`.

## Why aurora-cli uses `dart build cli` and not `dart compile exe`

The package's dependency graph includes a package with a build hook
(`objective_c`, pulled in by `path_provider_foundation`), and `dart compile exe`
refuses to run when it sees one. That hook is a no-op on non-Apple platforms, so
the bundle that `dart build cli` produces on Linux contains nothing besides the
single executable `bundle/bin/aurora_cli`, which can be installed directly as
`/opt/aurora/aurora-cli`.

`dart build cli` does not support `--define`, so the version is not injected at
compile time: `aurora-cli` reads `data/flutter_assets/version.json` from the
install directory at runtime. That is the file Flutter itself generates and that
`package_info_plus` also reads on Linux, so the GUI and the command line always
report the same version (see `app/lib/cli/cli_install.dart`).
