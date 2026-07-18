# Offload

A near-zero-friction capture app: press the Action Button, speak or type a passing
thought, and an **on-device** AI turns it into organized, contextual tasks. Nothing
leaves the phone by default.

- **Platform:** iOS 26+ (Apple Intelligence–eligible devices — e.g. iPhone 15 Pro / 16 / 17 line)
- **AI:** Apple Foundation Models framework (on-device, free, no download)
- **UI:** SwiftUI
- **Storage:** SQLite via GRDB (added in increment 2)

Built to the "AI-Powered Personal Organizer — Build Specification (v2)".

---

## How this project is built and tested

The author's Mac can't build iOS 26 apps, so **GitHub Actions is the source of truth**:
every push is compiled and tested on a real Apple Silicon Mac with Xcode 26
(see `.github/workflows/ios.yml`). Work lands in small, CI-verified increments.

### Build increments
1. ✅ **Skeleton + CI + design system** — 5 tabs, availability gate, Action Button intent
2. ⬜ Data layer (GRDB schema, Keychain key)
3. ⬜ AI extraction (`@Generable`, Foundation Models session)
4. ⬜ Capture flow (on-device transcription → extraction → save)
5. ⬜ Dedup, calendar tool, tabs wired to real data
6. ⬜ `.ipa` artifact for Sideloadly

---

## Getting it onto your iPhone 17 Pro — free (no paid Apple Developer account)

1. **Push this repo to GitHub.** CI builds it automatically.
2. Once increment 6 lands, download the built **`.ipa`** from the Actions run (artifacts).
3. On any Mac (even an old Intel one), install **[Sideloadly](https://sideloadly.io)**
   or **[AltStore](https://altstore.io)**.
4. Sign in with a **free Apple ID**, plug in the iPhone, and sideload the `.ipa`.
5. On the phone: **Settings → General → VPN & Device Management** → trust your Apple ID.
6. **Settings → Action Button → Shortcut → Offload · Quick Capture.**

> ⚠️ Free-Apple-ID apps expire after **7 days** and must be reinstalled. A paid Apple
> Developer account ($99/yr) removes that limit and unlocks TestFlight — optional, later.

---

## Building locally (if you get a capable Mac)

Requires macOS 15+ and Xcode 26.

```bash
brew install xcodegen
xcodegen generate
open Offload.xcodeproj
```

Then pick an iPhone simulator and press Run. The `.xcodeproj` is generated from
`project.yml` and is git-ignored — always regenerate it, don't hand-edit.
