# Build & CI — how to push and make an IPA

**Local machine cannot build** (macOS 12, no Xcode 26). CI is the only compiler.
The Xcode project is generated (`*.xcodeproj` is gitignored) — CI runs `xcodegen generate`.
New `.swift` files and `.ttf`/resources under `Offload/` are auto-included (directory globs).

## Workflow
- File: `.github/workflows/ios.yml` — runner `macOS-15`, Xcode 26.
- Two parallel jobs:
  - `test` (~12 min) — always runs on push to `main`.
  - `ipa` (~18 min) — **opt-in**: only runs if the commit message contains `[ipa]`, or via manual `workflow_dispatch`.
- The `ipa` job uploads the signed `.ipa` as a build artifact.

## To push + get an IPA
```bash
cd ~/Desktop/Offload
git add -A
git commit -m "Short summary (vX.Y.Z) [ipa]

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git push origin main
```
Bump `project.yml` `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` each build.
Only push when the user explicitly asks. Watch: `gh run watch <id> --exit-status`.
Download artifact: `gh run download <id> -n <artifact> -D ~/Desktop/Offload-App`.

## Blind-build safety (no local compiler)
Before pushing, verify: balanced `{}`/`()` per file, referenced symbols exist (grep),
tests updated in lockstep. Ignore local sourcekitd errors on `switch` expressions and
`#Preview` — the old local Swift false-flags them; Xcode 26 CI compiles them fine.
Desktop is TCC-protected: use the Read tool or `Bash --dangerouslyDisableSandbox`.
