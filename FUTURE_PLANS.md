# Offload — Roadmap

*Living document. Last updated against **v3.0.0 (build 56)**.*

**How this file works.** Three sections: **Now**, **Next**, **Later**. Shipped work is *deleted
from here*, not annotated — `git log` is the history, and a roadmap that doubles as a changelog is
how the previous version of this file ended up describing a v0.2 app while v2.6 was on the phone.
Decisions that were argued out and settled live in §5 so they don't get re-litigated.

---

## 1. Where the app actually is

Five tabs: **Home · Day · Gym · Study · Settings**. Search and Projects live inside Home.

**Home is four screens, not one.** The clock picks which (`DayPhase`), and each shows one thing
with nothing else on it: **Morning** — the day's shape and a commitment; **Now** — a single task,
full screen; **Tonight** — the day's two numbers and the shutdown; **Wind down** — a box to empty
your head into, and no counts at all. Two of the four boundaries are decisions rather than hours:
planning the day ends the morning, closing it out ends the evening. The old everything-at-once
Home survives intact as **Everything**, one tap away from every phase, and the phase can be
overridden by hand from the same menu.

**Capture has kinds now** (v3.0.0). Every captured item is classified before anything else —
`task · idea · note · decision · question · waiting · commitment · event · reflection`
(`CaptureKind`) — and the kind decides what the app may do with it. Only a task, a commitment or an
event can be scheduled; everything else is timeless by construction, enforced in `CaptureMapper`
rather than merely asked for in the prompt. The **fidelity rule** is the half people notice: a task
is rewritten into an imperative, and everything else keeps the user's own words, because with an
idea the wording *is* the content. Venting produces no row at all. Below 0.7 confidence the result
screen offers a one-tap *To-do / Idea* chip, and tapping it is recorded as a correction.

**The model knows the person now** (v3.0.0). `CaptureContext` assembles a full briefing for every
extraction: the **Life brief** (six short fields the user wrote, plus what the app noticed), **the
project list with exact titles** — the block that stops near-duplicate projects existing — what
they've worked on in the last fortnight, what's currently outstanding, their glossary, and up to
twenty past corrections **ranked by resemblance to what was just said** rather than by recency.

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

**Projects are a workspace** (v3.0.0). `ProjectWorkspaceView`: a **hill chart** with its own
history (Basecamp's idea — the first half is figuring it out, the second is executing, and a dot
that hasn't moved in three weeks says *stuck* where a percentage never could), a nominated **next
action** with a way to start it, sections by kind (Next actions · Waiting on · Open questions ·
Ideas · Decisions · Notes), a dated **log**, a brief in the user's own words, target-date runway,
and archive. Ideas never count as outstanding work.

**Study & Gym.** Study tab with a subtag tree, standalone resources, and Anki priced by *answers*
rather than cards (again-rates and learning steps included). Gym tab with AI-planned weekly
sessions materialised as real blocks.

**Focus.** Live Activity timer on the Lock Screen and Dynamic Island, pomodoro breaks, survives
app termination. Every sitting is recorded against its task.

**Rituals.** Morning brief / "I'm up" replan; evening shutdown that turns unfinished work into a
decision instead of tomorrow's surprise. Daily habits with streaks. Grocery list. Since the Home
rework these aren't cards you might scroll past — the shutdown *is* the evening screen.

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

*Partly shipped in v3.0.0 — a project now has a hill, a log, a next action and a user-written
brief. What remains below is the automatic half: the brief that rewrites itself as the project
moves, rather than one you press a button for.*


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

### 4.5 If-then plans

The single best-evidenced behaviour-change mechanism there is, and almost no task app has it.
A reminder says *"do the thing"* at a time you picked once. An **implementation intention** binds
the action to a **cue you will actually meet** — "if it's 7pm and cardio Anki isn't done, then 20
cards before dinner". People who write plans in that form act on them at roughly twice the rate of
people who merely intend to, because the decision is made in advance and the cue does the
remembering.

Offload is unusually well placed to build this properly, because it already *knows* most of the
cues: the calendar, the plan, what's ticked, when a session ended, how long it ran, when a task was
last moved. A rule engine is only as good as the triggers it can actually detect, and everything
below is detectable today.

#### What a rule is

    IF   <trigger>   THEN   <action>            (scoped to: every day / weekdays / a module / a date range)

**Triggers the app can genuinely evaluate**

| Trigger | Reads |
|---|---|
| At a time, if something is still undone | plan + completion state |
| When a calendar block ends | EventKit |
| Right after a specific task or habit is ticked | task/habit writes |
| When a focus session ends early | `TaskSession` vs. the estimate |
| When a gap of N free minutes opens before the next commitment | today's timeline |
| When something hasn't happened in N days | habit checks / completions |
| When a task has been rolled N times | roll counter (see §5) |
| When tomorrow's plan exceeds my real capacity | `DayPlanner` + learned throughput |
| When I capture something after a given hour | capture timestamps |

**Actions**

Schedule a task now · start a focus block on it · open capture · tick a habit · surface one line on
the current phase screen · drop the smallest thing from tomorrow.

#### Examples worth shipping as templates

Authoring must be **templates with blanks**, never a general rule builder — a builder is a toy
nobody fills in twice. The starter library:

*Study*

1. If it's **7pm** and **cardio Anki** isn't done → **20 cards, now**, before dinner.
2. If **anatomy lab** ends → **15 minutes of the same topic's AmBoss questions**, immediately, while it's warm.
3. If a **UWorld block** finishes **early** → **review the ones I flagged**, with the leftover minutes.
4. If **tomorrow's Anki forecast is over 300** → **do 60 extra tonight**.
5. If I haven't touched a **module** in **3 days** → put **one 25-minute block** on tomorrow.
6. If a **lecture** is cancelled → the freed hour goes to **whatever's furthest behind**, not to the phone.

*Clinical*

7. If a **shift** ends → **one line on what I saw**, into the journal, before I leave the building.
8. If a **gap of 20+ minutes** opens between commitments → offer the **two-minute cache** (see §5).
9. If **rounds** end → **write up the one thing I couldn't answer** and queue it for tonight.

*Protecting the person*

10. If it's **11pm** → **wind down**, whatever's left. (The phase screen already does this; the rule makes it a commitment rather than a default.)
11. If I've had **no unplanned hour in 5 days** → **block two hours this weekend** before anything else claims them.
12. If **tomorrow's plan is over my real capacity** → **drop the smallest thing** and tell me which.
13. If I capture something **after midnight** → **don't schedule it tonight**; it lands on tomorrow's list unopened.

*Momentum*

14. If **morning Anki** is ticked → **start the next block immediately**, no re-deciding. (Chaining off a completion is the cheapest trigger in the list and the most reliable.)
15. If a task has been **moved 3 times** → **interview it** (§5): too big, unclear, or dead.

#### How it behaves

- **Delivery is a line, not a modal.** A fired rule appears as one sentence on whichever phase
  screen is showing, plus a local notification if the app is closed. It never interrupts a focus
  session and never stacks.
- **Once per day, per rule.** A `last_fired_day` key, the same day-key convention as habits and the
  shutdown.
- **It measures itself.** Every firing records whether the action followed. A rule ignored five
  times running gets offered for deletion, in its own words: *"This one hasn't worked since
  March — keep it?"* This is the part that stops the feature becoming another dead notifications
  screen, and it's the reason to build the honesty in from the first commit rather than later.
- **Gemini writes the rule, not the schedule.** "I keep skipping cardio Anki" → a proposed if-then
  in the user's own vocabulary, which the user then edits and accepts. Proposing is a good use of
  the model; firing is pure local logic and must never depend on the network.

#### Shape

`IfThenRule` (GRDB row: trigger kind + parameters, action kind + parameters, scope, `last_fired_day`,
fire/follow-through counts) · `IfThenEngine.due(rules:context:now:)` — pure, so every trigger is
unit-tested against a fixture day · evaluated in the existing background refresh and on app
foreground · one screen under Settings, plus inline authoring from a task's context menu.

---

## 5. Later

Kept because they're right, not because they're scheduled.

- **Capture surfaces**: share sheet from any app, Apple Watch dictation, Shortcuts actions,
  screenshot capture. Deferred deliberately — the app's front door works.
- **Roll counter, and a Not Doing list.** A task moved five times isn't a task, it's a symptom:
  count the rolls, mark the row quietly, and have the shutdown ask about that one specifically.
  Dropping something is a decision worth recording with a date and a line of why — otherwise it
  vanishes silently and comes back as guilt. Cheap to build; `rollToTomorrow` already exists.
  Referenced by §4.5.
- **Interview the stuck task.** Three questions on anything that's rolled five times, then rewrite
  it or kill it. Pairs with the roll counter; referenced by §4.5.
- **Two-minute cache.** A standing queue of things under two minutes, surfaced the moment a gap
  opens — between lectures, waiting for rounds. Small tasks currently have to compete with real
  ones for a place in the plan, always lose, and accumulate. Referenced by §4.5.
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
