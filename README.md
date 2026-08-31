# Offload

A near-zero-friction capture app: press the Action Button, speak a passing thought, and an AI turns
it into organised, scheduled work. The premise is that you say the thing and stop carrying it —
**an empty screen is success, not an empty state.**

- **Platform:** iOS 26+, iPhone only
- **AI:** **Gemini 3.1 Flash Lite**, for both extraction and day planning. Capture is
  Gemini-**only** as of v2.7.0 — the on-device fallback was removed on purpose (see below).
  `AIRouter` routes; `AIBudget` caps spend
- **Capture is typed:** every item is a `task`, `idea`, `note`, `decision`, `question`,
  `waiting`, `commitment`, `event` or `reflection` (`CaptureKind`). Only the first kinds can be
  scheduled — an idea is never a chore — and only a task is reworded; everything else keeps your
  words
- **Projects are a workspace:** hill chart with history, a nominated next action, sections by kind,
  a dated log
- **UI:** SwiftUI — five tabs: Home · Day · Gym · Study · Settings. Home itself is four
  single-purpose screens chosen by the clock (`DayPhase`: Morning · Now · Tonight · Wind down),
  with the older all-at-once view kept as **Everything**
- **Storage:** SQLite via GRDB, reactive `ValueObservation` streams
- **Calendar:** EventKit, read and write
- **Current version:** v2.7.0 (build 47)

### Why capture needs the network

Until v2.7.0, a capture that couldn't reach Gemini quietly fell back to a small on-device model.
That was worse than having no fallback: "I left my jacket in school" came back as those literal
words instead of *Retrieve jacket from school*, and **nothing anywhere said the good model hadn't
run**. You couldn't tell a bad day for the AI from a bad app.

Now, when Gemini can't run — no key, no network, budget spent, private mode — nothing is invented
and nothing is saved half-understood. Your words stay in the capture box, the app says exactly
which of those it was, and the retry is yours to make.

### About privacy — read this before assuming

Earlier versions of this app were on-device only, and earlier versions of this README said "nothing
leaves the phone". **That is no longer true.** Since v2.0, capture text and task titles are sent to
Google's Gemini API for extraction and day planning. What stays local: the database, embeddings
(`NLEmbedding`), everything the app has learned about you (`LearnedProfile`), and — by explicit
design — journal entries, which are never sent anywhere (see `FUTURE_PLANS.md` §3).

---

## How this project is built and tested

The author's Mac runs macOS 12 and **cannot compile this app at all**. GitHub Actions is the only
compiler and the source of truth: every push is built and tested on macOS 15 with Xcode 26. Work
lands in large, CI-verified increments, written blind and checked by CI rather than locally.

See **`BUILD_AND_CI.md`** for the workflow, the `[ipa]` opt-in convention, and the blind-build
safety checklist.

---

## What it does

**Capture.** Action Button or Siri opens a screen that is already recording. The raw transcript is
saved *before* extraction, so nothing is lost if the AI fails; a retry sweep re-extracts it later.
Extraction is intent-based — "I left my jacket in school" becomes *Retrieve jacket from school*,
"I keep forgetting to call mom" becomes *Call mom*, and pure venting produces no task at all.
Saying something already on your list doesn't create a second copy.

**Scheduling.** A deterministic quarter-hour planner (`DayPlanner`) does the placing; Gemini
supplies the ordering (`SmartPlanner`). Undated captures are auto-fitted into today. The timeline
self-heals as the day slips, routes around protected time and real calendar events, and rolls
overdue work forward so nothing sits in the past. Blocks are dragged directly on a time grid.

**Study and Gym.** A Study tab with a subtag tree and Anki priced by expected *answers* rather than
cards — again-rates and learning steps included. A Gym tab that plans the week and materialises
sessions as real blocks.

**Focus.** A Lock Screen and Dynamic Island Live Activity timer with pomodoro breaks that survives
the app being killed. Every session is recorded against its task.

**Rituals.** A morning replan, an evening shutdown that turns unfinished work into a decision, daily
habits with streaks, and a grocery list.

**Learning.** The app measures how long your work really takes versus what you estimated, when you
actually focus well, what your recurring work costs, and the vocabulary you use — then applies it to
planning and to the extraction prompt. All of it is visible, explained, and deletable under
**Settings → What Offload has learned**.

---

## Getting it onto the phone

CI builds an unsigned `.ipa` when the commit message contains `[ipa]`, or on a manual workflow
dispatch. Download it from the Actions run, then sideload with
[Sideloadly](https://sideloadly.io) or [AltStore](https://altstore.io) using a free Apple ID, and
trust it under **Settings → General → VPN & Device Management**.

Then: **Settings → Action Button → Shortcut → Offload · Quick Capture.**

> Free-Apple-ID builds expire after **7 days** and must be reinstalled. Free signing also cannot
> enable App Groups, push, or iCloud — which is why there is no Home Screen widget (a widget runs in
> its own process and would have no way to read the app's database). Live Activities work regardless,
> because ActivityKit pushes state from the app. A paid account ($99/yr) removes all of this.

---

## Building locally (if you get a capable Mac)

Requires macOS 15+ and Xcode 26.

```bash
brew install xcodegen
xcodegen generate
open Offload.xcodeproj
```

The `.xcodeproj` is generated from `project.yml` and is git-ignored — always regenerate it, never
hand-edit it. New `.swift` files under `Offload/` are picked up automatically by directory globs.

---

## The other documents

| File | What it's for |
|---|---|
| `FUTURE_PLANS.md` | The roadmap — Now / Next / Later, plus settled decisions |
| `BRIEF.md` | The app's shape and current feature set, for brainstorming from |
| `BUILD_AND_CI.md` | How to push, how to get an `.ipa`, blind-build safety |
| `TESTING.md` | On-device test script for the current build |
