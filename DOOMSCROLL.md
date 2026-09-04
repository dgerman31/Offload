# The scroll problem — what's built, and what's parked

*Built in v3.1.0 (build 58). Everything under "Parked" is deliberate, not forgotten.*

---

## 1. What iOS actually allows

Worth stating once, because it decides the shape of everything else.

**No app can see which other app you're in.** There is no foreground-app API, no reading another
app's screen, no accessibility tree for other processes. An app cannot know you opened Instagram.

There is exactly one official mechanism — **Screen Time** (`FamilyControls`, `ManagedSettings`,
`DeviceActivity`) — and it is genuinely good: `DeviceActivityMonitor` fires a callback at a usage
threshold, and `ManagedSettingsStore.shield` puts a full-screen block over an app that you design
yourself. Apps are chosen through a system picker that hands back opaque tokens, so your app never
learns which app it is. Properly private, properly enforced.

It needs `com.apple.developer.family-controls`, which requires **a paid developer account plus a
written approval request to Apple**. A free Apple ID cannot hold it — the same wall as App Groups
and the Home Screen widget.

So the sensor, for now, is a **Shortcuts personal automation** the user sets up: *when Instagram is
opened → run Offload's "Start scroll timer"*. Run Immediately, so it fires silently. It's a doorbell
rather than a lock — deletable in fifteen seconds — but it's the strongest thing available without
the entitlement, and it costs nothing on the days you don't want it.

---

## 2. Shipped

The **escalation ladder** (`ScrollGuard`), its **copy** (`ScrollLines`), the **session**
(`ScrollWatch`), the **notifications** (`ScrollNotifications`), a **Lock Screen timer counting up**
(`ScrollActivityWidget`), and **Settings → Scroll timer** with the setup instructions.

| Elapsed | What happens |
|---|---|
| 0–1 min | Nothing. The grace period is what keeps the rest usable. |
| 1 min | Live Activity appears, silent. A number where you'll see it, with no telling-off. |
| 2 min | First nudge, naming whatever you left open. |
| 4 min | One a minute. |
| 6 min | The same minutes, priced in cards. |
| 10 min | Every 45 seconds, and the jokes stop. |

The whole ladder is handed to `UNUserNotificationCenter` at the moment the session starts, because
nothing of ours is running afterwards — the app is suspended within seconds of switching to a feed.
18 notifications, which is the ladder's share of the 64 iOS allows per app.

### How it knows you left

The weakest joint in the design, and worth being explicit about. Four mechanisms, in order:

1. **The "Instagram → Is Closed" automation.** The intended path, and a real Shortcuts trigger — but
   a well-documented flaky one. It misses on force-quit, sometimes when the phone locks with the
   feed still open, and sometimes for no reason anyone has pinned down.
2. **Offload coming to the foreground ends the session.** If you're looking at Offload you are not
   in Instagram, and iOS hands us that signal for free. This is the backstop that matters most: it
   catches the case where you tapped a nudge, and the case where the close automation simply didn't
   fire.
3. **"I've stopped" on every nudge and on the Lock Screen bar.** One tap, no app switch.
4. **The ladder ends itself.** The last notification is at 17.5 minutes and the session caps at 30,
   so a missed close costs you a finite number of nudges rather than an evening of them.

Recorded time is capped at the 30-minute auto-end for the same reason: with a missed close, a
session can sit open until Offload is next launched, and writing three hours into the daily total
would make the one honest number here a fiction.

With Screen Time (§3.6) this entire question disappears — the system measures usage itself and
there's nothing to detect.

The off switch is **deliberately easy**: on the Lock Screen bar, on every notification's long-press,
and in Settings, in 15-minute / 1-hour / rest-of-today sizes. The instinct is to make it hard —
there's a real literature behind commitment devices — but an interruption you can't stop is one you
solve by deleting the app, and then it helps you never again.

---

## 3. Parked — the next things to build

### 3.1 Debt

Scroll minutes become a real obligation: 20 minutes of Reels schedules 20 minutes of Anki into
tomorrow, visible, with the reason attached. Probably the single idea most likely to change
behaviour, because it makes the cost concrete and *future* rather than abstract and immediate.
Needs a decision about what happens when the debt isn't paid — most likely nothing, because a
punishment loop is how this becomes something you delete.

### 3.2 The return trip

When you next open Offload after a session over ~10 minutes, it opens on a screen that won't dismiss
until you type one line about what you were avoiding. Not a guilt exercise: it's the highest-quality
journal entry the app will ever collect, captured while the pattern is live. Over a month it's a
dataset nothing else in the app can produce, and it feeds straight into the journal work in
`FUTURE_PLANS.md` §2.2.

### 3.3 The witness

No interruptions at all — just an honest weekly total and a graph of *when* it happens. Some people
need a cattle prod; some just need to discover they did nine hours last week and thought it was two.
`ScrollGuard.todaySeconds` already records the daily figure, so this is a screen, not a system.

### 3.4 Escalating and self-authored friction (the hard off switch)

If the easy snooze turns out to be too easy, the ladder of commitment devices, best first:

- **A cooling-off delay.** You can always turn it off — it takes effect in 20 minutes. Impulses
  don't survive 20 minutes, and it never makes you feel trapped, which is why it survives.
- **Type your own sentence.** You write one line when you set it up; disabling requires typing it
  back, exactly. You argue with your own words.
- **A window.** Only disableable between 7 and 8am — never at 11pm, which is the only time you'll
  want to.
- **Escalating cost.** First disable this week is free; the second needs the sentence; the third
  needs the sentence and the delay.
- **A visible ledger.** Every disable logged with a date, the count on the settings screen. No
  friction at all — just the fact that it's on the record.

Explicitly rejected: hiding the setting somewhere obscure. It's security theatre against someone who
wrote the app, and it makes the tool feel adversarial rather than chosen.

### 3.5 More apps, and time-of-day rules

The automation approach already generalises — TikTok, YouTube, X, all identical to set up. What's
missing is per-app ladders (a 2-minute grace for YouTube is wrong) and time-of-day rules (11pm
should start at rung three, 8am on a Sunday probably shouldn't run at all).

### 3.6 The paid-account version

With `FamilyControls` this stops being a workaround:

- A **shield** genuinely blocks the app — you cannot scroll past it. Your copy, your buttons.
- The shield's buttons are yours: *"Do 20 cards first"* / *"5 more minutes"*, and the second can
  cost something.
- Thresholds are enforced by the system, in an extension, so it survives force-quitting Offload and
  doesn't depend on an automation the user could delete.
- `ShieldConfiguration` and `ShieldActionExtension` are the two extension points; `DeviceActivity`
  supplies the thresholds.

The same $99/year also unlocks the Home Screen widget, push, iCloud backup, and ends the 7-day
re-sign cycle. This is the strongest single argument for it.

---

## 4. Things considered and dropped

- **Detecting Reels specifically** rather than Instagram as a whole. Not possible — the automation
  fires on the app, and nothing can see inside it.
- **Dimming or greying the other app's screen.** No API, at any price.
- **A background audio nag.** The app isn't running; a notification sound is capped at ~30 seconds
  and that's the whole budget.
- **Critical alerts** (bypassing the ringer switch). Needs its own Apple-approved entitlement, and
  would be a genuine misuse of one meant for medical and safety alerts.
