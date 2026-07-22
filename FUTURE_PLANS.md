# Offload — Future Plans

*Living document. Last updated: July 18, 2026 (v0.2.4 — round-2 punch list complete, pending CI). Nothing in here is forgotten; items graduate out as they ship.*

---

## 1. Where we are

**Shipped & CI-verified through v0.2.2:** full 5-tab app · capture by typing **and** voice (auto-submit on stop) · Foundation Models extraction with few-shot prompting + subtask hierarchy · calendar **read** grounding tool · dedup warnings with tunable sensitivity · semantic + token search · pattern suggestions (recurrence / break-it-down) with background synthesis · weekly insight · correction-history learning ledger · energy batching · streaks & stats · Siri lock-screen capture ("Hey Siri, tell Offload") · elite-pass UI (rings, icon tags, pills, numbered project order).

**Landed in v0.2.3–v0.2.4 (round-2 punch list — CI green):** lenient multi-strategy due-date parsing (timing bug) · auto-record on Action Button with a "type instead" escape · **blocking** dedup (Merge / Keep both / Skip before save) · subtask restraint (no trivial decomposition; ≥2 distinct steps, never restate the errand) · weekly insight 2.0 (reflection + concrete next steps from real open/overdue/streak data) · calendar **write** (real EventKit events for classified appointments, `calendar_event_id` stored).

**Landed in v0.2.7 — intent-based extraction (CI pending):** extraction reframed from "transcribe words" to "extract intent": problem statements invert into their fix ("left my jacket in school" → "Retrieve jacket from school"), meta-frames are stripped ("keep forgetting to call mom" → "Call mom"), vague intents become concrete next steps ("think about Q3 roadmap" → "Draft Q3 roadmap outline"), worry maps to the controllable action, commitments keep their recipient, and pure venting produces no task. Deliberate mode reasons about intent first. Deterministic `actionTitle` backstop strips fluff prefixes ("remember to", "need to", "try to", …) from every stored title. Also v0.2.6: "Erase all tasks" reset in Settings.

**Landed in v0.2.5 — "smarter AI" pass (CI green):** (1) **Grouping** — Home now pins an **Overdue** section above Focus, and every section is ordered by urgency (priority → soonest due → title) instead of capture order. (2) **Priority** — extraction rubric rewritten to weigh consequence + urgency + intensity (not just word loudness), plus a deterministic guardrail so anything due today/overdue is never shown as "low". (3) **Adaptive decomposition** — the prompt now teaches an explicit complexity spectrum (atomic errand → multi-step task → real project) so simple captures stay one line and genuinely involved ones get proportionally more structure.

**Distribution:** GitHub Actions builds unsigned `.ipa` → Sideloadly + free Apple ID → iPhone 17 Pro. 7-day re-sign cycle. Version bumps every build.

**Confirmed working on device:** priority inference, project restraint, subtask rendering, voice capture + auto-submit, on-device AI under free signing.

---

## 2. Round-2 punch list — ✅ COMPLETE (v0.2.3–v0.2.4, pending CI)

All six items implemented; confirm on device once CI is green and the fresh `.ipa` is sideloaded:

1. ✅ **Timing bug.** `DueDate` enum: lenient multi-strategy parsing at every read site + normalize to canonical ISO at save. Was: model emits `2026-07-19T09:00` (no tz) → strict `ISO8601DateFormatter` fails silently → "Anytime".
2. ✅ **Auto-record on Action Button.** Sheet opens already listening (one-shot `autoListen` flag on the coordinator); a distinct "Type instead" control stops the mic without submitting. In-app taps stay typing-first.
3. ✅ **Dedup blocks, not just warns.** `CaptureService` split into `prepare`/`finalize`; near-duplicates pause on a per-candidate **Merge / Keep both / Skip** choice before any insert. Headless Siri path still auto-keeps-both.
4. ✅ **Subtask restraint.** Prompt counter-examples + deterministic `restrainedSubtasks` guard: drops lone/duplicate/errand-restating sub-steps; keeps only ≥2 genuinely distinct ones.
5. ✅ **Weekly insight 2.0.** Model fed real open tasks, overdue count, category mix, and streak → short reflection + 1–2 concrete next steps. Deterministic fallback strengthened too.
6. ✅ **Calendar WRITE.** `CalendarWriter` (EventKit) behind a protocol; model classifies `isAppointment`, appointments with a due date become real events and store `calendar_event_id`.

**On-device verification checklist (do after next sideload):** appointment actually appears in Apple Calendar · dedup prompt fires with real embeddings · auto-record starts on Action Button press · insight reads as reflective, not a stat dump.

**Known-good to protect:** priority inference (rent→high), project gating (stamps ≠ project), voice auto-submit, mic-tap stop-and-submit (distinct from "type instead").

---

## 3. Design Language 2.0 — "elite pass" (after punch list)

### The DNA from the reference shots
- **A hero, not a list** — every screen leads with one focal element (greeting + gradient card / giant type over imagery / one big score ring). Lists read as admin; heroes read as product.
- **Warmth via personality** — "Good night, Olivia"; an assistant that speaks ("your score went down 28% — let's discuss").
- **Depth** — gradients, glass blur, layered cards, organic curves. Never flat white cells.
- **One playful accent** against a calm base (dark navy or warm cream).
- **Signature tab bar** — floating dock with a raised center action.

### Offload translation
- **Dark-first identity:** deep indigo-black base (`#0E1020` family); indigo→violet as *gradients*, not flat fills. Light mode = warm cream, not white.
- **iOS 26 Liquid Glass** materials for tab bar/sheets — instantly current-gen.
- **Home:** "Good evening, Daniel" → hero state card: "**3 things need you today** — everything else is handled." Gradient shifts with time of day (morning gold → evening violet). Focus = swipeable carousel; categories = bento tiles.
- **Today:** progress ring goes hero — segmented arcs per category, count-up animation, center = tasks cleared.
- **Suggestions = the assistant's voice**, first person, pill CTA: *"'Water the plants' keeps coming up — want me to make it weekly?"*
- **The capture orb:** floating center button, breathing idle animation, blooms into the listening waveform on press (pairs with auto-record).
- **Empty states as rewards:** empty Home = *"Mind clear. Nothing needs you right now."* For a cognitive-offload app, empty is success — that inversion is the soul of the product.
- **Motion vocabulary:** rings sweep, numbers count up, completions collapse with spring + haptic, project completion gets a one-second glow. Physical, never gratuitous.

### Design workflow & tooling
- **Mockup-first loop (primary):** Claude builds a pixel-level interactive HTML mockup (artifact/browser) → react → iterate in minutes → lock tokens → port to SwiftUI. Zero new tools; avoids burning CI cycles on visual iteration.
- **Figma official MCP connector** — add via claude.ai connector settings if curating designs personally; Claude reads frames/tokens directly.
- **Play (createwithplay.com)** — design native SwiftUI on the phone; exports SwiftUI.
- **SF Symbols 7 + Apple Design Resources** — free official kits; keeps custom work native-feeling.
- **Claude Code frontend-design plugin** — sharpens web-mockup output for the mockup-first loop.

---

## 4. Wellness expansion (the long game)

The core premise is already a wellness claim: *the user forgets nothing; the mind un-clenches.* Build the arc:

- **Mental Load score** — inverse health ring: "Your mind is holding 4 open loops."
- **Shutdown ritual (evening)** — 2-minute guided flow: review today → park tomorrow's first task → brain-dump anything lingering → "Day closed." Companion **morning brief**.
- **Focus sessions** — energy batching + timer + Do Not Disturb: "30 minutes, these 3 tasks."
- **Mood tag on capture** — one emoji-tap; AI correlates over time ("most anxious captures happen Sunday nights").
- **Journal lane** — non-task captures (feelings, ideas) get a home; weekly synthesis turns them into reflections.
- **HealthKit** — write mindful minutes for rituals/focus sessions.
- **Quiet hours** — windows where the app deliberately never nags.
- **Insight 2.0 ties it together** — *"You closed every loop 3 days straight. Thursday you overloaded — 9 captures, 1 done. Consider batching Thursday errands."*

---

## 5. Engineering backlog (spec + infrastructure, unscheduled)

- **Review sheet before save** (spec §5.5) — optional confirm/tweak of extracted tasks for high-stakes captures.
- **Streaming extraction preview** (spec §3.4) — tasks populate live via `streamResponse`; respect reduced-motion.
- **Fallback ladder** (spec §2.2) — bundled MLX open-weight model for ineligible devices; opt-in cloud for heavy synthesis behind the same `LanguageModelSession` API.
- **sqlite-vec migration** (spec §3.5) — move brute-force cosine to a `task_vectors` virtual table when task count grows.
- **Widgets + Lock Screen** — glanceable next-3-tasks, lock-screen capture button. Requires a widget extension target (extra bundle IDs — fine, stay stable).
- **Phase 2 spec features (9–14):** dependency/blocker chains · relationship tracking ("what do I owe Sarah?") · advanced habit learning · cross-capture synthesis & project briefs · NL quick-add.
- **Distribution decision:** $99 Apple Developer when the 7-day re-sign gets old → TestFlight (90-day builds, OTA) and unlocks App Store path.
- **Discipline:** bump `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` every build; large CI-verified increments; build-before-watch.

---

## 6. Recommended sequence

1. ~~**Punch list** (§2) — correctness first.~~ ✅ Done (v0.2.3–v0.2.4). Verify on device once CI is green.
2. **← NEXT: Design mockup sprint** (§3) — interactive HTML artifact → approve → port to SwiftUI.
3. **Wellness features** (§4) ride on the polished foundation.
4. **Engineering backlog** (§5) interleaved as needed; distribution upgrade when friction demands.

*Perfect what exists → make it beautiful → then expand.*

---

## §4. AI scheduling — "fit my day" (C) and recurring commitments (D)

Status: **designed, not built.** Build on existing engines — do NOT reinvent:
`Routine` model (fixed/flexible, `timesPerWeek`, `flex`, `RoutineException`),
`RoutinePlanner` (picks lightest days), `DayPlanner.plan/candidates` (fits work into
open time around events, honors energy/preferred-hours), `LiquidTimeline` (reflow soft
tasks). Calendar writes go through `CalendarWriter` (already gated).

### C — auto-fit a capture into the day
After a capture with NO stated time, run a second Gemini pass that places the task into
the best open slot for that day, given the day's existing events + tasks + the user's
preferred hours. If the user DID state a time, keep it pinned there — never move it.
Placements are **soft** (`isSoftScheduled`, unpinned) so `LiquidTimeline` can reflow them.
Open product forks (ask the user):
  - Intrusiveness: silent soft-place vs. propose-a-chip-to-confirm vs. only-on-a-button.
  - Reach when today is full: spill to next open day vs. keep today (reflow) vs. leave undated.
Wire point: `CaptureService` after extraction/insert; reuse `DayPlanner` for the slotting
math, or let Gemini return a proposed `dueDate` (soft) it can't for stated-time captures.

### D — natural-language recurring commitments
Parse input like: "gym 5x/week ~45min afternoons unless I have class that day (campus gym);
class M–Th 9–12, Tue/Thu 2–5" into commitments and block them out.
Map to the existing model:
  - Fixed commitments (class M–Th 9–12, Tue/Thu 2–5) → **fixed `Routine`s** (specific days+times).
  - Flexible commitments (gym 5x/week, afternoons) → **flexible `Routine`** (`timesPerWeek`=5,
    preferred hours = afternoon), auto-scheduled by `RoutinePlanner` into open days.
  - Conditionals ("unless class that day", "campus gym if on campus") → `RoutineException`s /
    per-day constraints the planner respects (skip/relocate on class days).
Needs: a Gemini extraction schema for commitments (kind, days, time window, count, prefs,
conditions), then create `Routine`(s). Flexible ones reuse the C engine to place sessions.
Open product fork (ask the user):
  - Storage: **internal Offload blocks/routines** (reversible, not in Apple Calendar) vs.
    **real iOS Calendar events** via EventKit vs. ask per-commitment.
Target: "flawlessly execute" the gym/class example above end-to-end.

### Decisions (locked 2026-07-21)
- C intrusiveness: **Silent & movable** — auto-place undated captures as soft blocks, no confirm; stated times stay pinned.
- C reach when today is full: **Keep it today** — force into today; `LiquidTimeline` reflows/overflows the rest (no spill to other days).
- D storage: **Internal Offload blocks** — commitments live as `Routine`s inside Offload; NOT written to Apple Calendar.
