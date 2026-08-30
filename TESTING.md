# Offload — on-device test script

*For **v2.7.0 (build 47)**. Rewritten 31 July 2026; the previous version of this file tested
v1.0.0 and had been wrong for roughly forty builds.*

Sideload the `.ipa` from the CI run, then trust it under **Settings → General → VPN & Device
Management**. This covers what's changed recently and what CI cannot check — anything involving a
finger, a Lock Screen, or several days of real use.

---

## Tier 1 — the fixes that need confirming

### 1. Dragging a block actually sticks
Day tab → press and hold a task block → drag it down an hour → release.

- It should **stay where you put it**, not spring back. (It sprang back until v2.6.0: the row id is
  prefixed `task-…` and the lookup was searching for a task with that as its id, so nothing was
  ever written.)
- **Scrolling must still work afterwards.** Drag, then immediately scroll. Also start a drag and
  cancel it by dragging off the edge, then scroll. Both must work — a cancelled drag used to leave
  the scroll view frozen until the app restarted.
- Try it on a gym-linked block and on a real calendar event: neither should move.

### 2. Completing a task on the Day tab makes it disappear
Visit another tab first, come back, then complete something from the Day tab. It should vanish
immediately. (The shared task stream was torn down when Home disappeared, so nothing was observing
tasks and every list except Home went stale.)

### 3. The Home cards stay live
- Home → Groceries → add three items → back. The card must read **"3 to get"**, not "Nothing on the
  list".
- Home → tick a daily habit; it ticks and stays ticked. Tick it again and it unticks. Repeat after
  switching tabs a few times. Both cards froze permanently after the first navigation away.

### 4. Anki counts are typable
Home → "I'm up" → the Anki card → tap the number and type `217`. The estimate above should update as
you type. The ± buttons still work.

---

## Tier 2 — what's new

### 4b. Capture fails honestly (v2.7.0)
Turn on Airplane Mode and capture something. It must **keep your words**, say plainly that it
couldn't reach Gemini, and leave the retry to you — never save a half-understood task. Repeat with
the API key removed, and with Private Mode on: each should name its own reason. Then reconnect and
confirm `CaptureRetrySweep` picks the capture up.

### 5. Evening shutdown
Appears **after 8pm**, and only when there's something to close out. Home → "Close out the day".
- Tick something you actually did, drop something you didn't, leave the rest alone.
- The button says "Move N to tomorrow" — N should count only what you left alone.
- Work with a real time keeps that hour tomorrow; whole-day work lands as whole-day.
- Once closed out, it shouldn't ask again until tomorrow.

### 6. Habit streaks
Tick a habit three days running — a flame and a count appear. Miss a day and it resets. **Not having
ticked today must not zero it** — the day isn't over.

### 7. The now line
Day tab, today: a red line at the current time, and the view opens scrolled to it. Yesterday and
tomorrow have no line and open at the top.

### 8. Time spent against the estimate
Run the focus timer against one task across a few sittings. Task detail should show *"1h 10m of 2h
estimated"*. Push past the estimate and it offers to revise it.

### 9. What Offload has learned
**Settings → What Offload has learned.** Expect it to be nearly empty for a couple of weeks — that's
correct. Everything is sample-gated: 5 finished timed tasks for drift, 12 focus sessions for the
energy curve, 3 repetitions for an estimate prior, 8 scheduled blocks for plan outcomes. Check that
"Recalculate now" doesn't hang and that "Forget everything" empties it.

Once it fills in, any task whose estimate the app changed shows an **"Adjusted for you"** card with
the reason and a one-tap revert. Confirm the revert restores the old number.

---

## Tier 3 — still unresolved

### 10. The Live Activity on the Lock Screen
Known issue: the focus timer appears in the Dynamic Island but has been reported blank on the Lock
Screen. To narrow it down:

1. Start a focus timer, then lock the phone.
2. **Settings → Data → Diagnostics**, `app` category:
   - *"Started the focus Live Activity (now 1 active)"* → the app asked correctly and the widget
     extension isn't rendering. Most likely Sideloadly rewriting bundle IDs so the extension no
     longer matches its host app.
   - An error line → ActivityKit refused the request.
   - Nothing at all → Live Activities are disabled for the app.
3. Also check **Settings → Face ID & Passcode → Live Activities** — a separate switch, and the one
   that would explain "Dynamic Island yes, Lock Screen no".

---

## Regressions worth a glance

Cheap to check, and all have broken before: voice capture auto-submits when you tap the mic again ·
"rent's due friday" produces *Pay rent*, Finance, high, due Friday · venting produces no task ·
saying something already on your list says "Already got it" instead of adding a second copy ·
appointments appear in Apple Calendar · planning at 2pm never schedules anything into the morning.
