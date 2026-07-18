# Offload — Future Plans

*Living document. Last updated: July 18, 2026 (v0.2.2 shipped). Nothing in here is forgotten; items graduate out as they ship.*

---

## 1. Where we are

**Shipped & CI-verified through v0.2.2:** full 5-tab app · capture by typing **and** voice (auto-submit on stop) · Foundation Models extraction with few-shot prompting + subtask hierarchy · calendar **read** grounding tool · dedup warnings with tunable sensitivity · semantic + token search · pattern suggestions (recurrence / break-it-down) with background synthesis · weekly insight · correction-history learning ledger · energy batching · streaks & stats · Siri lock-screen capture ("Hey Siri, tell Offload") · elite-pass UI (rings, icon tags, pills, numbered project order).

**Distribution:** GitHub Actions builds unsigned `.ipa` → Sideloadly + free Apple ID → iPhone 17 Pro. 7-day re-sign cycle. Version bumps every build.

**Confirmed working on device:** priority inference, project restraint, subtask rendering, voice capture + auto-submit, on-device AI under free signing.

---

## 2. Round-2 punch list (next build session — in this order)

1. **Timing bug — top priority.** Everything lands in "Anytime"; no immediate dues.
   Prime suspect: model emits due dates without timezone (`2026-07-19T09:00`) and our strict `ISO8601DateFormatter` fails silently → task treated as dateless. Fix: lenient multi-strategy parsing everywhere dueDate is read + normalize to canonical ISO at save. Fallback hypothesis: model not emitting dueDate → surface raw value in edit sheet to verify, strengthen prompt.
2. **Auto-record on Action Button.** Capture screen should already be listening when opened via Action Button (spec §2.3 says exactly this), with a visible "type instead" switch that stops the mic.
3. **Dedup should block, not just warn.** Near-duplicate detected → present **Merge / Keep both / Skip** before saving (original spec §3.5 behavior). Also verify embeddings actually fire on device.
4. **Subtask restraint.** No decomposing errands into trivial steps ("go to the store to buy X" = ONE task). Subtasks only for ≥2 genuinely distinct sub-steps; never restate the errand itself. Prompt counter-examples.
5. **Weekly insight 2.0.** Not a stat readout — feed the model real data (top open tasks, overdue list, category mix, streak) and ask for a short reflection + 1–2 concrete next steps.
6. **Calendar WRITE.** Meetings/appointments (only those) become real calendar events via EventKit; store `calendar_event_id` (column already exists). Model classifies appointment-ness during extraction.

**Known-good to protect:** priority inference (rent→high), project gating (stamps ≠ project), voice auto-submit.

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

1. **Punch list** (§2) — correctness first.
2. **Design mockup sprint** (§3) — interactive HTML artifact → approve → port to SwiftUI.
3. **Wellness features** (§4) ride on the polished foundation.
4. **Engineering backlog** (§5) interleaved as needed; distribution upgrade when friction demands.

*Perfect what exists → make it beautiful → then expand.*
