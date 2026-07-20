# Offload v1.0.0 — What's New & How to Test It

Sideload `~/Desktop/Offload-App/Offload.ipa`, then trust it under
**Settings → General → VPN & Device Management**.

**Do this first:** Settings → Data → **Erase all tasks**. Most of these features only look
right against fresh data, and old test tasks were captured before the extraction fixes.

---

## Tier 1 — Test these first (biggest changes)

### 1. Extraction that captures intent, not words
Capture each of these by voice and check what you get:

| Say this | Should produce | Should NOT produce |
|---|---|---|
| "I left my jacket in school" | **Retrieve jacket from school** | "forget jacket" |
| "I keep forgetting to call mom" | **Call mom** | anything about forgetting |
| "ugh this codebase is a mess" | **nothing** (venting) | a vague "codebase" task |
| "create a project for future app ideas, I want subfolders and a details field" | A project + **exactly 2 tasks** | a 5-step lifecycle plan with invented dates |
| "rent's due friday" | **Pay rent**, Finance, **high**, due Friday | medium priority |

> The 4th row is the exact failure you screenshotted. It should no longer invent
> "Research app management systems / Design architecture / Develop / Test / Launch",
> and should attach **no due dates or effort estimates** you didn't mention.

### 2. Plan my day
Add 4–5 tasks with no dates, make sure you have a calendar event or two today, then tap
**Plan my day** on Home.
- Tasks should fill the **real gaps** between your meetings, never overlapping them
- Nothing scheduled **in the past** — planning at 2pm starts at 2pm
- 5-minute buffers between tasks
- Anything that doesn't fit is listed as **"Didn't fit today"**, not crammed in
- Tap the **slider chip** → set "Best hours" → demanding work should move into that window
- Drop a row with ✕, then **Schedule** — accepted times appear on the Home timeline

### 3. Reminders that you can act on
Settings → Reminders → turn on **"Remind me when tasks are due"** (allow notifications).
Create a task due ~2 minutes out, then **lock your phone**.
- Notification fires
- **Long-press it** → "Mark done" and "In an hour"
- "Mark done" completes it *without opening the app* — verify in the app afterwards

### 4. Recurrence actually repeats
Add a task → schedule it → **Repeat: Every day** → save → complete it.
- Undo banner says **"next one scheduled"**
- Tomorrow's date now has that task (check the week strip / Calendar)
- Previously this did nothing at all

---

## Tier 2 — Daily-use features

### 5. Light / dark mode
Settings → Appearance → Automatic / Light / Dark. Light mode should look *designed*
(cool off-white, white cards floating) — not plain white.

### 6. Week strip + timeline (Home)
- Tap days in the strip to look ahead; dots show which days are busy
- The day renders as a **connected timeline** — events and tasks on one rail, colour-coded
by category, past items dimmed

### 7. Manual add + natural language
Tap **+** on Home. Type `lunch with Sam tomorrow 1pm`.
- A row appears offering **"Schedule for tomorrow 1:00 PM"**
- Tapping it sets the date and trims the title to "lunch with Sam"
- It should **offer**, never auto-apply

### 8. Focus timer
Long-press any task → **Focus X min** → full-screen countdown ring.
Finish or "Done early" → task completes, minutes bank into Insights.

### 9. Waiting on someone
Long-press a task → **Waiting on someone**.
- Gets an amber "Waiting" chip
- **Excluded from Plan my day** (you can't do it)
- Weighs less in Mental Load
- Appears under Search → **Waiting on**

### 10. Mental Load
Home shows an inverse ring — *lower is calmer*. Add overdue tasks and watch it climb;
the advice line should change with the band (Clear → Light → Full → Heavy).

### 11. Daily rituals
Open the app **before 11am** → "Morning brief" card. **After 7pm** → "Close the day".
The evening one: review what closed, one-tap roll leftovers to tomorrow, and a final
brain-dump that runs through the normal capture pipeline.

---

## Tier 3 — Structure & organisation

### 12. Project subfolders
Projects → **+** → create one → long-press it → **Add subfolder**.
Progress should **roll up**: a parent counts everything beneath it.

### 13. Task detail screen
Tap any task (previously went straight to an edit form).
- Read-first view: details, steps with **"2 of 5 done"** progress bar, people, repeat rule
- **Add a step** inline at the bottom
- Focus / Snooze / Delete buttons; Edit in the top-right

### 14. People & commitments
Capture "send Sarah the deck" and "call Sarah about the invoice".
Search → scroll past the smart lists → **People** → Sarah → everything you owe her.
Also try Siri: **"Hey Siri, what do I owe someone in Offload"**.

### 15. Smart lists
Search now opens on **Overdue / Today / This week / High priority / Unscheduled /
Waiting on / Completed** with live counts.

### 16. Bulk actions
Search → open a list → **Select** (top right) → tick several → bar appears with
**Done / Snooze / Delete**.

### 17. Custom categories
Settings → Learning → **Categories** → add e.g. "Studying".
It appears in pickers *and* the AI will file into it.

---

## Tier 4 — Quieter things

| # | Feature | Where |
|---|---|---|
| 18 | **Insights screen** — streaks, focus minutes, mental load, weekly review, where your week went | Settings → Your progress → Insights |
| 19 | **Habit learning** — peak hour, effort bias, neglected categories (silent until ~12 completions) | Insights → "How you work" |
| 20 | **Weekly review** — flags tasks you keep deferring and stale undated ones | Insights → "Your week" |
| 21 | **Journal** — every capture in your own words, including ones that made no task | Settings → Journal |
| 22 | **Project briefs** — "where are we with this?" written on-device | Open any project |
| 23 | **Data export** — one JSON file you own | Settings → Data → Export everything |
| 24 | **Siri: "what's on my plate"** | Lock screen |
| 25 | **Live waveform** while dictating | Capture screen, tap the mic |
| 26 | **Onboarding** — only shows on a fresh install | Delete + reinstall to see it |
| 27 | **Duplicate task** | Long-press any task |
| 28 | **Consistent actions** — same long-press menu on every screen | Home / Search / Calendar |
| 29 | **Swipe actions** | Inside a project |
| 30 | **Auto-record** — Action Button opens already listening, with "Type instead" | Press the Action Button |

---

## What I'd most like feedback on

1. **Does the extraction feel right now?** That's the heart of the app and the thing CI
   can't verify — the model only runs on your phone.
2. **Is "Plan my day" useful or gimmicky?** It's the biggest new bet.
3. **Motion intensity** — scroll transitions and the card cascade. Too much? Too subtle?
4. **Is Home too busy?** It now has hero, week strip, now/next, plan, ritual, mental load,
   suggestions, overdue, timeline, batch, whenever. That may be too many cards competing.

## Known limitations

- **Calendar events need a real device** — the simulator has no EventKit data
- **Notifications need permission** — grant them in onboarding or Settings
- **Habit learning stays silent** until ~12 completed tasks (by design — an app that claims
  to know you after three tasks is lying)
- **7-day sideload expiry** on a free Apple ID; reinstall to renew
