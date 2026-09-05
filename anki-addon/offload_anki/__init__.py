"""Offload — Anki bridge.

Pushes a small JSON snapshot of *one deck's* progress to a private GitHub gist, which the Offload
iPhone app reads. Counts only: how many reviews and new cards you've done today, how many are left,
and the review forecast for the next couple of weeks. No card content, no note text, no deck
contents — nothing that isn't a number.

Why a gist rather than talking to the phone directly: AnkiConnect only works while the Mac is awake
and on the same Wi-Fi, which is precisely not the case when you're out and want to know whether
you're on top of your cards. A gist is free, needs no server to run, and is reachable from anywhere.

Why the forecast is computed *here* rather than in the app: every new card you finish today becomes
a review tomorrow or the day after, so a forecast worked out this morning is wrong by lunchtime.
Recomputing it from the collection on every push means it can never drift — the numbers come from
the same table Anki schedules from.
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

from aqt import mw, gui_hooks
from aqt.utils import showInfo, tooltip

ADDON = __name__.split(".")[0]
GIST_FILENAME = "offload-anki.json"
API = "https://api.github.com/gists/"


# ---------------------------------------------------------------------------
# Config


def config() -> dict:
    return mw.addonManager.getConfig(ADDON) or {}


def deck_name() -> str:
    return (config().get("deck") or "").strip()


# ---------------------------------------------------------------------------
# Reading the collection
#
# Everything below is a direct query against the same tables Anki schedules from, filtered to the
# one deck tree we care about. `coalesce(nullif(odid,0), did)` is the home deck: a card sitting in a
# filtered deck keeps its original deck in `odid`, and without this a cram session would make the
# whole deck look empty.


def deck_ids() -> list[int]:
    """The deck and every subdeck under it. Empty if the name doesn't match anything."""
    name = deck_name()
    if not name:
        return []
    prefix = name + "::"
    return [
        d.id
        for d in mw.col.decks.all_names_and_ids()
        if d.name == name or d.name.startswith(prefix)
    ]


def day_cutoff() -> int:
    """Epoch seconds of the *next* rollover — Anki's own day boundary, not midnight."""
    sched = mw.col.sched
    for attr in ("day_cutoff", "dayCutoff"):
        value = getattr(sched, attr, None)
        if value:
            return int(value)
    return int(time.time())


def snapshot() -> dict | None:
    col = mw.col
    ids = deck_ids()
    if not ids:
        return None

    id_list = ",".join(str(i) for i in ids)
    home = f"coalesce(nullif(c.odid,0), c.did) in ({id_list})"
    home_plain = home.replace("c.", "")

    today = int(col.sched.today)
    cutoff = day_cutoff()
    day_start_ms = (cutoff - 86400) * 1000
    now = int(time.time())

    # Done today, from the review log joined back to cards so the deck filter applies.
    #
    # `count(distinct cid)` and not `count()`: the bar is about *cards you got through*, and a card
    # you pressed Again on three times is one card, not three. Counting answers would make the bar
    # race ahead on a bad day, which is exactly backwards.
    reviews_done = col.db.scalar(
        f"select count(distinct r.cid) from revlog r join cards c on c.id = r.cid "
        f"where r.id >= ? and r.type = 1 and {home}", day_start_ms
    ) or 0
    # type 0 is a card being learned for the first time.
    new_done = col.db.scalar(
        f"select count(distinct r.cid) from revlog r join cards c on c.id = r.cid "
        f"where r.id >= ? and r.type = 0 and {home}", day_start_ms
    ) or 0
    # Every answer, including repeats. Not what the bar is drawn from — it's what tells you how much
    # work today actually took, which on a heavy Again day is a very different number.
    answers_today = col.db.scalar(
        f"select count() from revlog r join cards c on c.id = r.cid "
        f"where r.id >= ? and {home}", day_start_ms
    ) or 0

    # Still waiting. Queue 2 is review, 1 is intraday learning (due is a timestamp), 3 is
    # day-learning (due is a day number), 0 is new.
    reviews_remaining = col.db.scalar(
        f"select count() from cards c where {home} and c.queue = 2 and c.due <= ?", today
    ) or 0
    learning_remaining = (
        col.db.scalar(f"select count() from cards c where {home} and c.queue = 1 and c.due <= ?", now) or 0
    ) + (
        col.db.scalar(f"select count() from cards c where {home} and c.queue = 3 and c.due <= ?", today) or 0
    )
    new_available = col.db.scalar(
        f"select count() from cards c where {home} and c.queue = 0"
    ) or 0

    # The deck's own new-per-day limit, so "new remaining" means what Anki will actually show you
    # rather than how many unseen cards exist in total (which for a shared deck is tens of thousands).
    try:
        conf = col.decks.config_dict_for_deck_id(ids[0])
        new_limit = int(conf["new"]["perDay"])
    except Exception:
        new_limit = 0
    new_remaining = max(0, min(new_available, new_limit - new_done)) if new_limit else new_available

    # The forecast. Reviews already scheduled for each of the next N days.
    #
    # This is what makes the number honest as the day goes on: a new card you finish now graduates
    # into a real `due` day, so it shows up here the next time this runs. Nothing has to be
    # invalidated or re-derived — the query simply sees the new state.
    days = int(config().get("forecastDays") or 14)
    rows = col.db.all(
        f"select c.due - ?, count() from cards c "
        f"where {home} and c.queue = 2 and c.due > ? and c.due <= ? "
        f"group by c.due order by c.due", today, today, today + days
    )
    forecast = [{"day": int(d), "reviews": int(n)} for d, n in rows]

    _ = home_plain  # kept for readability of the queries above

    return {
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "deck": deck_name(),
        "dayCutoff": cutoff,
        "today": {
            "reviewsDone": int(reviews_done),
            "newDone": int(new_done),
            "answersDone": int(answers_today),
            "reviewsRemaining": int(reviews_remaining),
            "learningRemaining": int(learning_remaining),
            "newRemaining": int(new_remaining),
        },
        "forecast": forecast,
    }


# ---------------------------------------------------------------------------
# Pushing


def push(payload: dict) -> None:
    cfg = config()
    gist_id = (cfg.get("gistId") or "").strip()
    token = (cfg.get("githubToken") or "").strip()
    if not gist_id or not token:
        return

    body = json.dumps(
        {"files": {GIST_FILENAME: {"content": json.dumps(payload, indent=2)}}}
    ).encode("utf-8")
    request = urllib.request.Request(
        API + gist_id,
        data=body,
        method="PATCH",
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "User-Agent": "offload-anki",
        },
    )
    urllib.request.urlopen(request, timeout=15).read()


_last_push = 0.0


def sync_now(force: bool = False) -> None:
    """Build a snapshot and push it, off the UI thread.

    Debounced, because the natural place to call this is after every single answer and a network
    round trip per card would make reviewing feel like wading. The interval is short enough that the
    phone is never more than a minute behind, and a forced push on session end catches the rest.
    """
    global _last_push
    interval = float(config().get("minSecondsBetweenPushes") or 60)
    if not force and time.time() - _last_push < interval:
        return
    _last_push = time.time()

    payload = snapshot()
    if payload is None:
        return

    def work(_=None):
        try:
            push(payload)
            return None
        except (urllib.error.URLError, urllib.error.HTTPError, OSError) as error:
            return error

    def done(future):
        error = future.result()
        if error is not None and config().get("showErrors"):
            tooltip(f"Offload: couldn't push ({error})")

    mw.taskman.run_in_background(work, done)


# ---------------------------------------------------------------------------
# Hooks


def on_answer(reviewer, card, ease) -> None:
    sync_now()


def on_reviewer_end() -> None:
    # Force: the last few answers before you close the reviewer are the ones most likely to be
    # swallowed by the debounce, and they're also the ones that finish the queue.
    sync_now(force=True)


def on_sync_finish() -> None:
    # Reviews done on the phone arrive here, so this is where a day's AnkiMobile session lands.
    sync_now(force=True)


def on_profile_open() -> None:
    sync_now(force=True)


def test_connection() -> None:
    payload = snapshot()
    if payload is None:
        showInfo(
            f"Offload: no deck named “{deck_name()}”.\n\n"
            "Set it in Tools → Add-ons → Offload → Config, exactly as it appears in your deck list."
        )
        return
    try:
        push(payload)
    except Exception as error:  # noqa: BLE001 — this is the diagnostic path; show whatever broke
        showInfo(f"Offload: push failed.\n\n{error}")
        return
    today = payload["today"]
    showInfo(
        "Offload: pushed.\n\n"
        f"Deck: {payload['deck']}\n"
        f"Done today: {today['reviewsDone']} reviews, {today['newDone']} new\n"
        f"Left: {today['reviewsRemaining']} due, {today['newRemaining']} new\n"
        f"Forecast: {len(payload['forecast'])} days"
    )


gui_hooks.reviewer_did_answer_card.append(on_answer)
gui_hooks.reviewer_will_end.append(on_reviewer_end)
gui_hooks.sync_did_finish.append(on_sync_finish)
gui_hooks.profile_did_open.append(on_profile_open)

# One menu item, for setting it up and for answering "is this thing on?".
_action = mw.form.menuTools.addAction("Offload: push Anki progress now")
_action.triggered.connect(test_connection)
