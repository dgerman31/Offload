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

## Tier 2.5 — the HIG pass (v2.8.0)

None of this can be checked by CI. Liquid Glass doesn't even render correctly in the simulator, so
the whole appearance layer is device-only.

### 11. Text actually scales now
**Settings → Accessibility → Display & Text Size → Larger Text.** Drag it up.
- Every screen's text should grow. Before this build, almost none of it did — 87 places used a
  fixed point size.
- Push it to the largest accessibility size and walk Home, Day, Study, Gym, Settings. Look for
  **truncation, overlap, and anything you can no longer reach.** That's the failure mode, and it's
  the part I couldn't test.
- Then drop it to the smallest size and check nothing collapses.

### 12. Reduce Motion is honoured
**Settings → Accessibility → Motion → Reduce Motion.** Turn it on.
- Cards should no longer slide up and stagger in when a screen opens — they fade.
- Scrolling should no longer scale or lift cards as they cross the screen.
- Buttons should still dim when pressed, but not shrink.
- Turn it back off and confirm the choreography returns.

### 13. Colour is readable in light mode
Switch to **light** appearance (Settings → Appearance). The semantic colours were all failing
contrast and have been darkened:
- Habit labels and Study accents (teal), the evening nudge (amber), completion ticks (green), and
  overdue markers (red) should all read clearly against white cards and the cream background.
- They should look like the same colours, just deeper. If any reads as muddy or brown rather than
  "darker teal/amber/green", tell me — that's a hue drift I'd want to correct.
- Check dark mode too: the primary indigo used as *text* was previously invisible on dark cards
  (1.72:1). Anywhere indigo text appears on a dark surface should now be plainly legible.

### 14. The tab bar minimises
Scroll down any long screen: the tab bar should shrink away, and come back when you scroll up.

### 15. Liquid Glass
Look at the tab bar, navigation bars, and sheets. On iOS 26 these should carry the system's glass
material. **This is the check I most need from you** — I can't see it, and if it isn't there it
means something in the app is opting out of the system chrome.

Also turn on **Reduce Transparency** and confirm nothing becomes unreadable.

---

## Tier 2.6 — Home by time of day (v3.0.0)

Home is no longer one screen. `DayPhase` picks between four, and the fastest way to test all of
them is the **⋯ menu → Show** picker, which overrides the clock. Everything below can be checked in
five minutes at any hour.

**16. The four screens exist and are actually different**
Open Home, then step through Morning · Now · Tonight · Wind down in the Show picker. Each should be
full-screen with one idea on it and no cards. If any of them scrolls past a second screenful of
content, something has leaked back in.

**17. The override clears itself**
Pick a phase that isn't the current one. Leave the app, come back. You should still be on the one
you picked — the override survives a foreground. Now leave it long enough for the real phase to
change (or step the device clock past a boundary): it should snap back to the clock's choice on its
own, without you clearing anything.

**18. Morning ends when you decide, not at noon**
Before noon, Home should say **Morning**. Tap **Plan the day**, submit a plan → you should land on
**Now** immediately, not at 12:00. Tapping **Start the day** without planning should do the same.
Kill and relaunch the app: still **Now**. Tomorrow morning it must be **Morning** again — the flag
is a day key, so a plan made yesterday must not skip today's.

**19. Now shows exactly one task**
Only one task title, large, with at most one dimmed "Then …" line under it. **Something else**
should swap to a different task each tap and never go blank — when it runs out of alternatives it
comes back round rather than showing the clear state. **Mark done** ticks it and the next one takes
its place, with the undo banner appearing at the bottom. With nothing left, you get "Nothing needs
you" rather than a blank screen.

**20. Tonight ends when the day is closed**
After 8pm Home is **Tonight**, with a done/open pair of numbers. Run the shutdown to the end →
Home should become **Wind down**, not offer the shutdown a second time. Both numbers should match
what the shutdown sheet itself lists.

**21. Wind down shows no counts at all**
The 10pm screen: a heading, a text box, one button. **No task count, no progress, nothing
outstanding anywhere on it** — that's the whole point of the screen, and it's the thing most likely
to regress. Type something, tap **Put it down**: it should go to "Goodnight." immediately, and the
text should turn up in the journal (Search → Journal) as a capture.

**22. Everything is still reachable and still works**
⋯ menu → **Everything**. The old Home, as a sheet: running list, pinned projects, habits,
groceries, suggestions, All tasks, All projects. Check swipe-to-delete and the steps disclosure
still behave here — this is the same view as before the rework, so anything broken here is a
regression, not a new bug. **Done** closes it.

**23. Dynamic Type and the big screens**
Largest accessibility size, on all four phases. The huge headline should shrink rather than
truncate; the bottom buttons must stay on screen and stay tappable. A long task title on **Now** is
the worst case — check one with 60+ characters.

---

## Tier 2.7 — capture kinds, the life brief, and projects (v3.0.0)

The biggest behavioural change in the app's history: a capture is no longer always a to-do.

**24. An idea comes back as an idea**
Say, roughly: *"I have a few more ideas for the Offload app — I want the AI to get a better picture
of my life for planning, and I could do a step 1 review of one topic a day with a practice question
from a topic list."* You should get a project (or a suggestion to file under the existing one) and
**ideas kept close to your own wording** — not three short imperative to-dos. Check each one: **no
due date, no overdue, and it doesn't appear in Plan my day.** This is the exact capture that
prompted the change; if it comes back as chores, nothing else in this tier matters.

**25. The fidelity rule**
Compare a to-do and an idea from the same words. "I need to email the PI about the dataset" as a
to-do should become "Email the PI…"; captured as an idea it must keep the "I need to" framing. A
long idea should be shortened for the row and kept **whole in the details** — open it and check.

**26. Nothing timeless can be scheduled**
Run **Plan my day** with several ideas and notes on your list. None of them may be given a time.
Check the Now screen too — it must never offer an idea as the thing to do next.

**27. The confidence chip**
Say something genuinely ambiguous — *"maybe I should start doing a topic a day"*. You should get a
one-tap **To-do / Idea** pair. Tap Idea: the date should disappear with it. Then check
**Settings → Correction history** — the tap should be recorded.

**28. Reclassifying by hand**
Long-press any row → **It's a…** → Idea. Same result: kind changes, schedule is stripped, a
correction is recorded.

**29. Notes have no checkbox**
A note or a decision should show its own glyph where the completion circle would be. A thing you
can't finish must not be able to look unfinished.

**30. Projects file into the right project**
With "Offload app" already existing, capture something mentioning it. It must land in **that**
project — not a new "Offload App" or "the Offload app". This is what the project list in the prompt
is for, and near-duplicates are the failure it prevents.

**31. The project workspace**
Open any project. Check: the **hill chart** drags smoothly and the label changes ("Figuring it out"
→ "Over the hill"); releasing writes a **log** entry; the **next action** card shows the top of Next
actions and **Start focus** works; dragging a different row to the top changes which one is
nominated; each section's **+** adds a row of that section's kind; **Archive** moves it to the
collapsed Archived section on the Projects list, and it can be opened and unarchived from there.

**32. Stalled detection**
Not testable in five minutes without moving the clock — if you want to force it, set a hill
position, then change the device date forward three weeks. The header should say "Hasn't moved in N
days."

**33. The life brief**
First launch after updating: the short **About you** setup should appear once on the Morning screen
and never again if skipped. **Settings → About you** should show everything you wrote, let you edit
it, and forget it. Then, on a later morning, a single question should appear under the plan —
answer it and check it lands in the right field; dismiss one and confirm that question never returns.

---

## Tier 2.8 — the three fixes (v3.0.1)

**34. Everything has a real door**
Every phase screen should show a labelled **Everything** button at the top left — same place on all
four. One tap opens it, Done closes it. It's gone from the ⋯ menu, which now holds Projects and
Search.

**35. The focus timer no longer blocks the tab bar**
Start a focus session, then tap Day, Gym, Study, Settings. Every tab must be reachable while the
timer runs. The mini bar now sits in the tab bar's own accessory slot (iOS 26's Apple-Music-style
placement), so it should also slide down into the bar as you scroll, and it should look like a
single glass capsule rather than a card inside a card.
*Watch for:* an empty capsule above the tab bar when **no** timer is running. That's a known iOS 26
quirk with this API — tell me if you see it.

**36. Nothing drags sideways any more**
Open **Everything** with a task that has a long category, a person's name and two or three context
tags on it, and try to drag the screen left and right. It must not move. The cause was `FlowLayout`
answering "how wide would you like to be?" with every chip on one line; that ideal width travelled
up to the ScrollView, which then scrolled horizontally because its content really was wider than
the screen. Also check the Day tab and Search, which use the same chips.

---

## Tier 2.9 — the scroll timer (v3.1.0)

**Set it up first.** Shortcuts → Automation → ＋ → App → Instagram → **Is Opened** → Run Immediately
→ action **Start scroll timer**. Then a second one for **Is Closed** → **Stop scroll timer**.
Settings → Scroll timer has the same steps written out.

**37. The ladder, on a stopwatch**
Open Instagram and leave it. At **1 min** a Lock Screen bar should appear counting up — silent. At
**2 min** the first notification, naming a task you have open. At **4 min** they should come once a
minute; at **6 min** they start quoting a card count; at **10 min** every 45 seconds. Read a few —
they should be funny and on your side, never a telling-off. Report any that land wrong; the copy is
easy to change and it's the part that decides whether you keep this on.

**38. It stops when you stop**
Close Instagram. Notifications must stop **immediately** and the Lock Screen bar must disappear. A
nudge arriving after you've stopped is the failure that makes the whole feature read as broken.

**39. The off switch, three ways**
Long-press any nudge → **Quiet for 15 min**. The Lock Screen bar's **15m** button. Settings → Scroll
timer → Quiet for an hour. All three must silence it *and* end the running session.

**40. It doesn't repeat itself**
Over one long session no two notifications should say the same thing. Across two days the opening
line should differ.

**41. Live Activity may not appear — that's known**
Starting a Live Activity from a background automation isn't guaranteed by iOS. If the Lock Screen
bar never shows but the notifications do, that's the known limitation, not a bug — tell me and the
copy for minute one moves into a notification instead.

**42. Nothing else broke**
Task reminders still fire and still offer Mark done / In an hour on long-press. The scroll category
is registered in the same call, and getting that wrong would silently delete the task actions.

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
