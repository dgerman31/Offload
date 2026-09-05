# Offload — Anki bridge

Pushes one deck's daily progress from Anki Desktop to a private gist, which the Offload iPhone app
reads to draw the progress bar and the avalanche forecast.

**Counts only.** Reviews and new cards done today, what's left, and the review forecast. No card
content, no note text, no deck contents — nothing that isn't a number.

---

## Why a gist

`AnkiConnect` only works while the Mac is awake and on the same Wi-Fi, which is precisely not the
case when you're out and want to know whether you're on top of your cards. A gist is free, needs no
server to run, and is reachable from anywhere.

## Setup, once

**1. Make a gist.** github.com/gist → filename `offload-anki.json`, content `{}` → **Create secret
gist**. Copy the long hex id from the URL.

**2. Make a token.** GitHub → Settings → Developer settings → **Fine-grained personal access
tokens** → Generate new. Give it **Gists: Read and write** and nothing else. Copy it.

**3. Install the add-on.** Copy the `offload_anki` folder into your Anki add-ons folder — in Anki:
**Tools → Add-ons → View Files**, then drop it beside the others and restart Anki.

**4. Configure it.** Tools → Add-ons → select **offload_anki** → **Config**. Set `deck` to your deck
name exactly as it appears in the deck list, and paste the gist id and token.

**5. Check it.** **Tools → "Offload: push Anki progress now"**. It should report what it found. If it
says the deck doesn't exist, the name doesn't match — it's case- and spacing-sensitive.

**6. In Offload:** Settings → Study → Anki, paste the same gist id and a token, and tap Check now.

## When it pushes

After an answer (debounced to once a minute), when you close the reviewer, after a sync, and when
you open your profile. The debounce exists because a network round trip per card would make
reviewing feel like wading; the forced pushes catch everything the debounce swallows.

## If you review on your phone

The add-on runs on the desktop, so phone reviews only reach it once **AnkiMobile has synced to
AnkiWeb and the desktop has synced down**. Leaving Anki open on the Mac makes that automatic — the
`sync_did_finish` hook pushes as soon as it lands. Otherwise the numbers are as fresh as your last
desktop sync, which is worth knowing before you distrust them.

## What it reads

Every figure comes from the same tables Anki schedules from, filtered to your deck tree:

| Figure | Source |
|---|---|
| Reviews / new done today | `revlog`, since Anki's own day rollover (not midnight) |
| Reviews still due | `cards` where `queue = 2` and `due <= today` |
| Learning still due | `cards` where `queue` is 1 or 3 |
| New remaining | unseen cards, capped by the deck's new-per-day limit |
| Forecast | `cards` where `queue = 2`, grouped by day, for the next fortnight |

Cards sitting in a filtered deck are counted against their **home** deck (`odid`), so a cram session
doesn't make the deck look empty.

The forecast is computed here rather than in the app on purpose: every new card you finish today
becomes a review tomorrow or the day after, so a forecast worked out in the morning is wrong by
lunchtime. Recomputing from the collection on every push means it can't drift.
