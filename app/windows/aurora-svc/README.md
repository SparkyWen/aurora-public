# Windows packaging components (place them here)

When the Aurora Windows app is built, the three files in this directory are copied
next to `aurora.exe` (see the install rules in `app/windows/CMakeLists.txt`). All
three are binaries and are **not committed** (they are gitignored); place them
manually before building:

| File | Source |
|---|---|
| `sing-box.exe` | the official release **1.13.14** amd64 (`sing-box-1.13.14-windows-amd64.zip`), kept in step with the version pinned in `core/go.mod` (CI takes it from `SINGBOX_VERSION`) |
| `wintun.dll` | the official wintun distribution (`wintun.zip` -> `bin/amd64/wintun.dll`) |
| `aurora-svc.exe` | built from `desktop/aurora-svc/` in this repository, cross-compiled: `GOOS=windows GOARCH=amd64 go build -o aurora-svc.exe ./...` |

Then:

```bash
cd app
flutter build windows --release
```

The output is in `build/windows/x64/runner/Release/`, with the three components
next to `aurora.exe`. The distribution form is an Inno Setup installer built from
that directory (see `app/windows/installer/aurora.iss`).

> If any file is missing, CMake prints a WARNING and skips it (the app still
> builds, but connecting will fail). `release.yml` asserts that all three exist so
> such a package is never published.

None of these files contains a contract. The app starts empty and you add a server
by importing an `aurora://` link; a private fork may embed a contract at
`app/assets/configs/aurora-contract.json`.
