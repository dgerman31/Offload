# Offload — Roadmap

*Living document. Last updated against **v2.7.0 (build 47)**.*

**How this file works.** Three sections: **Now**, **Next**, **Later**. Shipped work is *deleted
from here*, not annotated — `git log` is the history, and a roadmap that doubles as a changelog is
how the previous version of this file ended up describing a v0.2 app while v2.6 was on the phone.
Decisions that were argued out and settled live in §5 so they don't get re-litigated.

---

## 1. Where the app actually is

Five tabs: **Home · Day · Gym · Study · Settings**. Search and Projects live inside Home.

**Capture.** Action Button and Siri open a screen that's already recording. Raw input is persisted
before extraction, so words survive an AI failure; `CaptureRetrySweep` re-extracts anything that
failed. Extraction is intent-based (problem statements invert into their fix, meta-frames are
stripped, pure venting produces nothing). Near-identical restatements of open tasks are dropped
with an "already on your list" result rather than duplicated.

**AI.** **Gemini 3.1 Flash Lite**, for extraction and for day planning. Capture is Gemini-**only**
since v2.7.0 — the on-device fallback was removed because it silently produced worse captures with
nothing saying the good model hadn't run. When Gemini can't run, the words stay in the box and the
app names the reason. `AIRouter` routes, `AIBudget` caps spend. Extraction prompts carry the user's
own correction history and vocabulary.

**Scheduling.** `DayPlanner` (deterministic, quarter-hour grid) with `SmartPlanner` (Gemini)
supplying the ordering. Auto-fit places undated captures into today. `LiquidTimeline` self-heals
as the day slips. Protected time, waking window, and routine commitments are respected. Overdue
work rolls forward automatically; nothing sits in the past. Blocks are dragged with a real
long-press gesture on a time grid with a live now line.

**Study & Gym.** Study tab with a subtag tree, standalone resources, and Anki priced by *answers*
rather than cards (again-rates and learning steps included). Gym tab with AI-planned weekly
sessions materialised as real blocks.

**Focus.** Live Activity timer on the Lock Screen and Dynamic Island, pomodoro breaks, survives
app termination. Every sitting is recorded against its task.

**Rituals.** Morning brief / "I'm up" replan; evening shutdown that turns unfinished work into a
decision instead of tomorrow's surprise. Daily habits with streaks. Grocery list.

**Learning from history** (v2.6.0). One `LearnedProfile`, rebuilt nightly by `LearningPass`:
measured drift sizes the blocks the planner reserves and corrects estimates at capture; a measured
energy curve overrides the declared best-hours picker; phrase-level estimate priors; a learned
glossary of the user's own vocabulary; plan-outcome statistics fed back into the planning prompt.
All of it visible and deletable under **Settings → What Offload has learned**.

**Constraints.** Sideloaded with a free Apple ID: no App Groups, so **no Home Screen widget that
reads app data**, no push, no iCloud, and a 7-day re-sign cycle. Live Activities work anyway
(ActivityKit pushes state from the app). The developer's Mac cannot compile the app — CI is the
only compiler. See `BUILD_AND_CI.md`.

---

## 2. Now

### 2.1 Run the day, don't propose it

The app plans on a button press and then watches the day drift. It should hold the plan live.

- **A "Now" surface.** One card, always answering *what am I doing this minute* — the current
  block, time left in it, and what's immediately after. Home leads with it during working hours.
- **Drift detection.** At 2pm you're forty minutes behind. The app already knows: it has the plan,
  the clock, and the focus sessions. What's left reflows quietly rather than going wrong in
  silence. `LiquidTimeline` does the reflow; what's missing is anything *triggering* it.
- **Block boundaries as the heartbeat.** When a block ends, one tap: done / still going / stopped.
  This is the cleanest training signal available and it costs a single gesture. Feed it straight
  into `TaskSessionLog` and the learned profile.
- **Renegotiation, not failure.** When today provably cannot hold what's on it, say so at 11am
  with two or three specific things to move — not at midnight, and never as a scolding.
- **Runway.** Hours of usable day left against minutes of work outstanding, live. The single
  number that makes overcommitment visible while it's still fixable.
- **Live Activity as the day's spine.** It already survives termination and ticks itself; it
  should carry the *next block*, not only a running timer.

**Build order:** Now surface → block-boundary check-ins → drift-triggered reflow → runway →
renegotiation → Live Activity extension. Each is independently useful; none needs the next.

### 2.2 The journal

Deliberately specified in full below (§3). It is the largest genuinely *new* surface on this
roadmap and the one most easily ruined by building it like the rest of the app.

---

## 3. The journal — full design

### Why it exists

The app's premise is that you say a thing and stop carrying it. But everything you say currently
becomes a **task**, which means feelings get converted into work or discarded. The extraction rules
already say "pure venting produces no task" — so today, venting produces *nothing at all*. You
speak, and the app throws it away.

The journal is the other half of the braindump: some things you say need to be **held**, not
actioned. A place to put the thing that isn't a to-do, and then close the phone.

### Non-negotiable principles

1. **Private means encrypted, not hidden.** A passcode screen over a readable SQLite file is a UI
   illusion. Entries are encrypted at rest with AES-GCM (CryptoKit), the key held in the Keychain
   behind biometry. Someone with the phone's file system gets ciphertext.
2. **Nothing goes to Gemini.** Not for extraction, not for tagging, not for "insights", not
   silently as context in some other prompt. The single exception is an explicit, per-entry
   *"reflect on this"* that the user taps, that names what will be sent, and that is off by
   default. Journal text is the most sensitive content in the app and it must never be
   incidentally included in a prompt built for something else.
3. **No tasks are extracted.** Writing *"I hate this rotation"* must never produce a task called
   "Quit rotation". There is an explicit "there's something to do in here" affordance; nothing
   happens without it.
4. **No streaks, no counts, no gamification.** A journal with a streak becomes an obligation, and
   an obligation is the opposite of release. This is why the habit card's streak logic must not be
   reused here. No word counts, no "you haven't written in 6 days".
5. **It locks itself.** Immediately on backgrounding, not after a timeout. The app switcher preview
   is covered — a privacy overlay on `scenePhase != .active`, before the snapshot is taken.
6. **Delete means delete.** No soft-delete tombstone, no undo banner holding the text in memory.
   Everywhere else in the app soft-delete is right; here it is a betrayal.

### Shape

- **Entry**: freeform text, a timestamp, an optional mood, optional tags. That's all. No title
  field — a title is a small act of composition and this surface must never feel like composition.
- **Getting in**: a Home entry point that shows *nothing about the contents* — no preview, no
  count, no "last written 3 days ago". Just a way in. Face ID, passcode fallback.
- **Writing**: full-screen, no chrome, cursor already in the text, autosaving. Voice dictation
  uses on-device `SFSpeechRecognizer`, never a network transcription service.
- **Prompts**: a small, rotating, opt-in set for a blank page — *"What's taking up the most space
  right now?"*, *"What's the worst-case you're actually worried about?"*. Shown only when the page
  is empty and only if enabled. Never a notification.
- **Mood**: one tap, five states, skippable. Its only job is to make the entry findable later and
  to feed the load picture (§4.2) *if* the user opts in.
- **Finding things**: on-device search over decrypted text in memory. By date, by mood, by tag.
- **The escape hatch from capture**: when extraction decides a capture was venting and produces no
  task, offer to keep it in the journal instead of dropping it. That is the moment the two halves
  of the app meet, and it's the one place the journal is allowed to be suggested.

### Explicitly out of scope

Sharing. Rich text. Photos (an encrypted blob store is a different project). Sentiment scoring.
Anything that turns writing into data the app has opinions about.

---

## 4. Next

### 4.1 Module-based exam readiness, planned backwards

The real unit of study is a **module** with an exam date and a fixed body of work to get through:
all the Anki for the topic, all the AmBoss questions, all the UWorld questions. Readiness is
"have I finished the material with time to spare", and the plan should be derived from that.

- **Module model**: name, exam date, and a set of **resources**, each with a total, a completed
  count, and a per-item cost.
  - *Anki* — reuse `AnkiLoad`: priced in expected **answers**, not cards, with again-rates and
    the two-correct-in-a-row rule for new cards. Already built and tested; do not re-derive it.
  - *AmBoss / UWorld* — priced per question including review time, configurable per bank, with the
    same drift correction the rest of the app now applies to estimates.
- **Backward plan**: from the exam date and the waking window, derive the daily throughput each
  resource needs, then emit real blocks — *"UWorld cardio ×20 (40m)"*, *"Anki cardio, 120 due
  (35m)"*. These are ordinary tasks, so the day-runner, drift correction, and rollover all apply
  for free.
- **Honest status**: *"You're 3 days behind on UWorld and 1 day ahead on Anki"*, with the daily
  number required to catch up, computed from what's actually left rather than a percentage bar.
- **Re-spread on slip**: a missed day redistributes across what remains instead of producing
  overdue debris. If the remaining days can no longer hold the material, say so — that is the
  single most useful thing the app could ever tell a student, and it should say it in week two,
  not the night before.
- **Multiple modules at once**: the pressure map (§4.4) is where competing modules resolve.

### 4.2 Mental load and reflection

- **Load score**: an inverse ring — *"your mind is holding 4 open loops"*. Weighted by age,
  priority, and how long something has been rolling. It must go **down** when you close things,
  and the app should name the one action that would reduce it most.
- **Mood over time**: from the journal, opt-in, correlated with load and completion. *"Your worst
  weeks are the ones that start with more than nine open loops."*
- **Sleep from HealthKit** (read-only): last night quietly lowers today's ambition rather than
  announcing itself.
- **Burnout signal**: sustained overcommitment plus falling completion over a fortnight is worth
  one gentle sentence, once.

### 4.3 Living project briefs

Your research project has months of captures that currently form no picture. For each project,
Gemini maintains a short page from everything attached to it: what this is, where it stands, what's
blocked, what's next. Regenerated on the nightly pass when the project has changed, not on every
open. `ProjectBrief.swift` is the seam this extends.

### 4.4 Weekly synthesis, and the pressure map

- **Synthesis**: two honest paragraphs on the week from completions, drift, abandoned blocks, and
  what rolled repeatedly — ending in two concrete changes. Not a stat dump. The existing weekly
  insight is the seam; the material it's fed is what changes.
- **Pressure map**: four weeks out, which weeks are already overloaded — before you agree to
  anything that lands in them. This is also where two modules with adjacent exam dates get
  reconciled.

---

## 5. Later

Kept because they're right, not because they're scheduled.

- **Capture surfaces**: share sheet from any app, Apple Watch dictation, Shortcuts actions,
  screenshot capture. Deferred deliberately — the app's front door works.
- **Vision capture**: photograph a syllabus or rotation schedule and get a term of blocks. The
  biggest single unlock available, and Gemini is already multimodal. Ranked below the journal and
  the day-runner only because it's a large build.
- **Ask your own data**: natural-language questions and commands over everything stored, with the
  model planning and the app executing deterministically behind a confirm.
- **Write Anki cards**: AnkiMobile exposes `addnote` (verified — it's the *due-count read* that
  has no API, not the write). Capture a fact, generate cloze cards into the deck.
- **Spaced lecture review**: lectures as objects with review state on a 1/3/7/21-day ladder.
- **Rotations and blocks** as first-class time structures.
- **Long input to structure**: five minutes of dictated lecture notes → tasks, summary, and facts.
- **Backup and restore.** *Raised and not scheduled — recorded so the risk is explicit: there is
  no backup of any kind today. A lost or wiped phone loses every task, capture, project, journal
  entry, and everything the app has learned. A local encrypted export/import works under free
  signing and needs no subscription.*
- **Paid developer account ($99/yr)** would unlock the Home Screen widget, push, iCloud sync, and
  TestFlight, and end the 7-day re-sign cycle.
- **sqlite-vec migration** for embedding search when the task count makes brute-force cosine slow.

---

## 6. Settled decisions

Recorded so they aren't re-argued. Reversing one is fine; forgetting it was decided is not.

| Decision | Call | Why |
|---|---|---|
| Auto-fit intrusiveness | Silent and movable | Undated captures land as soft blocks; stated times stay pinned. |
| Auto-fit when today is full | Keep it today | Force into today as a whole-day intention; never spill to another day. |
| Recurring commitments | Internal `Routine`s | Not written to Apple Calendar. |
| Task splitting for long work | No splitting | Long stretches on one task are how this user works; unfinished work rolls to tomorrow. |
| Anki session length | Never split | Anki is done in order, in one sitting. |
| Learned adjustments | Explain and allow revert | Every change says why and undoes in one tap. Learning that can't be seen is indistinguishable from a bug. |
| Drift measurement | Per finished task, against the *original* estimate | Per-sitting comparison measures nothing; anchoring to the raw estimate stops the correction oscillating. |
| Energy curve | Measured beats declared | Scored by minutes per sitting, not volume — volume would just re-learn the schedule the planner imposed. |
| Duplicate captures | Drop near-identical, keep anything timed | A wrongly-dropped task is work that silently never happens. |
| Journal and AI | Never sent, except one explicit per-entry action | See §3. |
| Med-school specificity | Not answered — currently general | The glossary and priors learn the domain from use; no hardcoded medical concepts yet. |
