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

## Tier 2.6 — Home, and the day's rituals (v3.1.1)

Home is the full picture now, permanently. The phase screens arrive over it and leave.

**16. Home is Everything**
Open the app. You should land on the running list, pinned projects, habits, groceries — the whole
board — not on a phase screen. There's no "Everything" button in the corner any more, because there
is nowhere else to be.

**17. A ritual arrives once, then gets out of the way**
Open the app in the morning: **Morning** should take over. Tap **Not now** — you're on Home. Close
and relaunch: it must **not** come back. Same for **Tonight** after 8pm and **Wind down** after 10.

**18. Acting on one also ends it**
Morning → **Plan the day**, submit the plan → the ritual closes and you're on Home, and it doesn't
return. Tonight → close out the day → same. Wind down → write something and put it down → same.

**19. The middle of the day never interrupts**
Between noon and 8pm, opening the app must always land on Home. **Now** should never appear by
itself — only from ⋯.

**20. Rituals on demand don't use up the day's turn**
⋯ → **Close out the day** at 2pm. Do it, close it. Now wait until the evening: **Tonight** should
still arrive on its own, because you went looking for that one rather than being offered it.

**21. Nothing floats above the tab bar**
With no focus timer running there must be **no white bar** above the tabs. Start a focus session:
the mini bar appears above the tab bar, and **all five tabs stay tappable**. Both of those were
broken in build 60.

**22. Dynamic Type**
Largest accessibility size on Home and on each ritual. Headlines shrink rather than truncate; the
bottom buttons stay on screen and tappable. A long task title on **Now** is the worst case.

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

## Tier 3.0 — the Anki bridge (v3.2.0)

**Set up the add-on first** — `anki-addon/README.md` has the six steps. Make the secret gist, make a
fine-grained token with **Gists: read and write** only, drop `offload_anki` into Anki's add-ons
folder, set the deck to `AnKing` exactly as it appears in your deck list, then
**Tools → "Offload: push Anki progress now"**. It reports what it found; if it says the deck doesn't
exist, the name doesn't match.

**43. The bridge connects**
Settings → Anki → paste the gist id and a token → **Check now**. The Last snapshot section should
fill in with your real numbers. A wrong token should say so in words ("GitHub refused the token"),
not fail silently.

**44. Only AnKing counts**
Have due cards in another deck. The numbers must ignore them completely — that's the deck filter,
and it includes subdecks (`AnKing::Step 1::Cardio`) automatically.

**45. The bar on Home**
Do some cards on the Mac, then open Offload. The bar should move. Check the count is *cards*, not
answers — press Again on the same card three times and the bar should advance by one, not three.

**46. It disappears when you're done**
Clear the queue. The card should vanish from Home entirely, and the Lock Screen bar should end. A
card reading "0 left" would defeat the point.

**47. The Live Activity actually appears — this is the one that failed before**
With cards due, open Offload. A bar should appear on the Lock Screen and in the Dynamic Island. The
scroll timer's never did, because it tried to *start* from the background, which iOS forbids. This
one only ever starts in the foreground and only updates from the background. **If it doesn't appear,
tell me** — check Settings → Face ID & Passcode → Live Activities first, and Offload's own
notification settings.

**48. It stays honest when the Mac sleeps**
Put the Mac to sleep mid-queue. The bar should keep showing the last real numbers and start saying
how old they are ("Updated 20 min ago"). It must never present stale figures as live.

**49. The rollover**
After 4am (or whatever your Anki rollover is), yesterday's snapshot must stop being shown as today's
— the card disappears and Settings says "This is yesterday's".

**50. The avalanche warning**
Only when a day is genuinely unlike the others: 1.5× your normal day and at least 120 reviews. A
flat week must say nothing. Do a batch of new cards and check the warning updates — new cards
graduate into future reviews, and the add-on recomputes the forecast on every push, so it should
never be stale in the way a morning-computed forecast would be.

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
