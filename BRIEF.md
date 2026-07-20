# Offload — App Brief (for brainstorming future features)

## What it is

**Offload** is a near-zero-friction thought-capture app for iPhone. You press the Action
Button, speak or type a passing thought, and an **on-device AI** turns it into organized,
contextual tasks. Nothing leaves the phone.

**The core promise:** you forget nothing, so your mind un-clenches. It's a cognitive-offload
tool first and a task manager second. The guiding inversion: **an empty screen is success**,
not an empty state — when Home says "Mind clear," the product worked.

## Technical shape

- **Platform:** iOS 26+, iPhone only (Apple Intelligence–eligible devices, e.g. iPhone 15 Pro / 16 / 17)
- **AI:** Apple Foundation Models framework — on-device, free, no network, no API cost.
  Typed extraction via `@Generable` structured output (constrained decoding, so no JSON parsing).
- **UI:** SwiftUI, 5 tabs (Home · Calendar · Projects · Search · Settings)
- **Storage:** SQLite via GRDB, reactive `ValueObservation` streams
- **Calendar:** EventKit, read *and* write
- **Embeddings:** `NLEmbedding` sentence vectors, on-device, for dedup + semantic search
- **Distribution:** GitHub Actions builds an unsigned `.ipa` → Sideloadly + free Apple ID.
  7-day re-sign cycle. No paid Apple Developer account yet, so **no TestFlight, no push
  notifications, no App Store**. Currently v0.3.1, single user (the developer).
- **Constraint worth knowing:** the developer's Mac can't build iOS 26, so **GitHub Actions
  CI is the only way to verify a build**. Every change ships as a large, CI-verified increment.

## Current features (all shipped and CI-verified)

**Capture**
- Action Button → capture screen that's *already recording* (auto-record), with a "type
  instead" escape that stops the mic without submitting
- Voice capture with on-device transcription; tapping the mic again stops *and* submits
- Siri lock-screen capture — "Hey Siri, tell Offload" runs the whole pipeline without unlocking
- Raw input is persisted *before* extraction, so words are never lost on AI failure

**AI extraction (the heart of the app)**
- **Intent-based, not transcription-based.** Problem statements invert into their fix
  ("I left my jacket in school" → "Retrieve jacket from school"); meta-frames are stripped
  ("I keep forgetting to call mom" → "Call mom"); vague intents become concrete next steps
  ("think about the Q3 roadmap" → "Draft Q3 roadmap outline"); pure venting produces no task
- **Complexity-matched structure:** atomic errand → one task; genuinely multi-step task →
  subtasks; real project → multiple tasks. Deterministic guards prevent over-decomposition
- **Priority** inferred from consequence + urgency + language intensity, with a guardrail so
  anything due today/overdue is never labeled "low"
- Categories, context tags (home/work/car/store/gym/phone/…), effort estimates, due dates
  with lenient multi-format parsing, recurrence rules (iCalendar RRULE)
- **Deliberate mode:** optional slower two-pass reasoning for better results on hard captures
- **Duplicate detection blocks before saving** — near-duplicates prompt Merge / Keep both / Skip
- Calendar-aware scheduling: the model reads your calendar to pick due times around busy windows
- **Calendar write:** the model classifies real appointments, which become actual EventKit events

**Organization & review**
- **Home = day dashboard.** Time-of-day gradient hero that leads with what needs you
  ("2 things are overdue" / "3 things need you today" / "Mind clear"), progress ring,
  Now & Next (next event + single best task), overdue, today's timeline, and an undated pile
- **Calendar tab:** interactive month grid with per-day density dots (events vs. tasks, red
  for high priority); tap any day for its real timeline — calendar events merged with tasks
  due that day, in the order they'll happen
- Projects with progress, semantic + keyword search, streaks & stats
- **Energy batching:** "I have 30 minutes" → a batch of tasks that actually fits
- **Pattern suggestions:** detects repeated captures and offers to make them recurring;
  flags stale tasks for breakdown. Never auto-applied
- **Correction learning ledger:** records where you overrode the AI
- **Weekly insight:** the model reads real open/overdue/streak/category data and writes a
  short reflection plus 1–2 concrete next steps
- Undo for completion/deletion; "Erase all tasks" reset

**Design**
- Spring-only motion system, scroll-driven entrance transitions, staggered card cascades,
  depth-based layering (soft shadows, not borders), dark-first deep indigo-black palette

## Already on the roadmap — please suggest things BEYOND these

**Wellness arc (planned):** Mental Load score ("your mind is holding 4 open loops") ·
evening shutdown ritual + morning brief · focus sessions with timer + Do Not Disturb ·
mood tagging on capture with correlation over time · journal lane for non-task captures ·
HealthKit mindful minutes · quiet hours.

**Engineering backlog (planned):** review sheet before save · streaming extraction preview ·
fallback model ladder for ineligible devices · sqlite-vec for scaling vector search ·
widgets + Lock Screen · dependency/blocker chains · relationship tracking ("what do I owe
Sarah?") · cross-capture synthesis & project briefs · natural-language quick-add ·
paid Apple Developer account → TestFlight.

## What would help most

Ideas that deepen the core promise — *capture is effortless and nothing is forgotten* —
especially ones that:
- exploit **on-device AI** in ways cloud task apps structurally can't (privacy, zero cost,
  always available, can read personal context freely)
- make the app feel like it **understands you over time** rather than just storing text
- reduce friction even further at the capture moment, or surface the right thing at the
  right moment without nagging
- work within the constraints: single-user, no push notifications, no server, iPhone-only

Also welcome: honest critique of what's over-built, what's missing that users of task apps
consider table stakes, and where this differs meaningfully from Things / Todoist / Reminders.
