# Offload — App Brief (for brainstorming future features)

*Accurate as of v2.7.0 (build 47). If this disagrees with `git log`, trust the log.*

## What it is

**Offload** is a near-zero-friction thought-capture app for iPhone. You press the Action Button,
speak a passing thought, and an AI turns it into organised, scheduled work.

**The core promise:** you forget nothing, so your mind un-clenches. It's a cognitive-offload tool
first and a task manager second. The guiding inversion: **an empty screen is success**, not an empty
state — when Home says "Mind clear," the product worked.

**Who it's for:** one user, a medical student who sets his own daily schedule. The app is
deliberately *not* deadline-or-pressure shaped — there is no red "overdue"; timing reads "Scheduled"
for fixed commitments and "Planned for" for soft ones. Work that slips rolls forward automatically
rather than accumulating as debt.

## Technical shape

- **Platform:** iOS 26+, iPhone only. Five tabs: **Home · Day · Gym · Study · Settings**
  (Search and Projects live inside Home).
- **AI:** **Gemini 3.1 Flash Lite** — extraction and day planning. As of v2.7.0 capture is
  Gemini-**only**: the on-device fallback was deliberately removed, because a small model silently
  standing in for a frontier one produced quietly worse captures with nothing saying the good model
  never ran. When Gemini can't run the words stay put and the app says why (`ExtractionUnavailable`).
  `AIRouter` routes; `AIBudget` caps spend. **This is not an on-device-only app** — capture text and
  task titles go to Google. What never leaves: the database, embeddings, the learned profile, and
  journal entries (planned, and specified as never-sent by design).
- **Storage:** SQLite via GRDB with reactive `ValueObservation` streams; one shared task stream
  (`SharedTasks`) rather than per-screen observations.
- **Calendar:** EventKit, read *and* write. **Embeddings:** `NLEmbedding`, on-device, for dedup and
  semantic search. **Focus:** ActivityKit Live Activity, Lock Screen and Dynamic Island.
- **Distribution:** GitHub Actions builds an unsigned `.ipa` (opt-in via `[ipa]` in the commit
  message) → Sideloadly + free Apple ID. 7-day re-sign cycle.
- **Free-signing constraints:** no App Groups, so **a Home Screen widget cannot read app data at
  all**; no push; no iCloud; no TestFlight. Live Activities are the exception and work fine.
- **Build constraint:** the developer's Mac (macOS 12) cannot compile the app. **CI is the only
  compiler**, so everything ships as a large, CI-verified increment written blind.

## Current features (all shipped and CI-verified)

**Capture**
- Action Button and Siri open a screen that's *already recording*, with a "type instead" escape
- Raw input persisted *before* extraction, so words survive an AI failure; `CaptureRetrySweep`
  re-extracts anything that failed once conditions change
- **Honest failure** — when Gemini is unreachable, out of budget, or has no key, the capture says
  which, keeps your words, and leaves the retry to you rather than saving something dumber
- **Intent-based extraction:** problem statements invert into their fix ("left my jacket in school"
  → *Retrieve jacket from school*), meta-frames are stripped ("I keep forgetting to call mom" →
  *Call mom*), vague intents become concrete next steps, pure venting produces nothing
- Complexity-matched structure: errand → one task; multi-step job → steps; real project → tasks
- Priority from consequence and urgency, with a guard so anything due today is never "low"
- **Duplicate handling in two tiers:** near-identical restatements of open tasks are dropped with an
  "already on your list" result; genuinely *similar* work still prompts Merge / Keep both / Skip
- Categories, context tags, effort estimates, lenient multi-format due-date parsing, RRULE recurrence
- Natural-language commitments ("gym 5×/week ~45min", "class M–Th 9–12") become `Routine`s, not tasks
- Appointments the model classifies as real become actual EventKit events

**Scheduling**
- `DayPlanner` — deterministic, quarter-hour grid, plans ~⅔ of free time, respects the waking
  window, protected time, real events, and pinned commitments
- `SmartPlanner` — Gemini orders the day; the deterministic planner places it
- Auto-fit puts undated captures into today; `LiquidTimeline` self-heals as the day slips
- Overdue work rolls forward automatically, keeping the hour you chose where you chose one
- **Day tab:** real time grid, live now line, long-press-drag blocks to any quarter-hour

**Study & Gym**
- Study tab: subtag tree, standalone resources, and **Anki priced by expected *answers*, not cards**
  — again-rates and the two-correct-in-a-row rule for new cards are in the arithmetic
- Gym tab: AI-planned weekly sessions materialised as real blocks

**Focus**
- Live Activity timer with pomodoro breaks; survives backgrounding and termination
- Every sitting recorded against its task (`TaskSessionLog`)

**Capture taxonomy** (v3.0.0)
- Every item is classified first: `task · idea · note · decision · question · waiting · commitment ·
  event · reflection` (`CaptureKind`). The kind decides what the app may do with it
- **Only a task, commitment or event can be scheduled.** Ideas, notes, questions and decisions are
  timeless by construction — enforced in `CaptureMapper`, not merely requested in the prompt
- **Fidelity rule:** a task is rewritten into an imperative; everything else keeps the user's own
  words, because with an idea the wording *is* the content
- Below 0.7 confidence, one *To-do / Idea* chip. Tapping it is recorded as a correction and taught
  back to the model
- `event` is the only kind that reaches the real calendar; the test is "would you be late for it?"

**What the model knows** (v3.0.0)
- `CaptureContext` assembles a full briefing per extraction: the **Life brief**, **the project list
  with exact titles** (the block that prevents near-duplicate projects), the last fortnight of work,
  what's outstanding, the glossary, and up to 20 corrections ranked by resemblance to the capture
- **Life brief**: six short fields the user writes in a four-question setup, topped up by at most
  one question every few days, shown under the plan on the Morning screen. Fully readable, editable
  and deletable under **Settings → About you**

**Projects as a workspace** (v3.0.0)
- **Hill chart** with history: figuring-it-out on the left, executing on the right; a dot that
  hasn't moved in 21 days is called stalled
- One nominated **next action**, with Start focus; drag a row to the top to nominate another
- Sections by kind, a dated **log**, a user-written brief, target-date runway, archive

**Rituals & Home**
- **Home is four screens and the clock picks** (`DayPhase`): **Morning** — the day's shape and one
  commitment · **Now** — a single task, full screen, nothing to compare it against · **Tonight** —
  the day's two numbers and the shutdown · **Wind down** — a box to empty your head into, and no
  counts at all
- Two boundaries are decisions, not hours: planning the day ends the morning, closing it out ends
  the evening. The phase can be overridden by hand, and the override clears itself
- **Everything** — the old all-at-once Home (running list, pins, habits, groceries, suggestions) —
  is one tap from every phase
- Morning "I'm up" replan; **evening shutdown** — what got done, what's left, where it goes
- Daily habits with a week of dots and streaks; grocery list

**Learning from history** (v2.6.0 — one `LearnedProfile`, rebuilt nightly)
- Measured **drift** sizes the blocks the planner reserves and corrects estimates at capture
- A measured **energy curve** (minutes per sitting, exposure-normalised) overrides the declared
  best-hours setting
- **Estimate priors** for work you've done repeatedly; a learned **glossary** of your own vocabulary
  fed into the extraction prompt; your **corrections** taught back to the model
- **Plan outcomes** — how previous plans actually went — fed into the planning prompt
- All of it visible, explained, sample-gated, and deletable under *Settings → What Offload has learned*

## Already planned — suggest things BEYOND these

See `FUTURE_PLANS.md`. In short: **running the day live** rather than proposing it; a
**passcode-protected private journal**; **module-based exam readiness** (Anki + AmBoss + UWorld,
planned backwards from the exam date); **mental load** and reflection; **living project briefs**;
**weekly synthesis**; a **pressure map** four weeks out. Deferred but wanted: vision capture of a
syllabus, share sheet, Apple Watch, writing Anki cards via `addnote`, ask-your-own-data, backup.

## What would help most

Ideas that deepen the core promise — *capture is effortless and nothing is forgotten* — especially
ones that:
- make the app feel like it **understands you over time** rather than just storing text
- surface the right thing at the right moment **without nagging**
- exploit the fact that this is one person's app with years of their real history in it — things a
  general task app structurally cannot do
- work within the constraints: single user, no push, no server, no widget, iPhone only

Also welcome: honest critique of what's over-built, what's missing that people consider table
stakes, and where this differs meaningfully from Things / Todoist / Reminders.
