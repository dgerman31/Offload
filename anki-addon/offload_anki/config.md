## Offload — Anki bridge

- **deck** — the deck to report on, exactly as it appears in your deck list. Subdecks are included
  automatically, so `AnKing` covers `AnKing::Step 1::Cardio` and everything else beneath it. Cards
  from every other deck are ignored entirely.
- **gistId** — the id of a *secret* gist you create once (the long hex string in its URL).
- **githubToken** — a fine-grained personal access token with **gist** write permission, and nothing
  else. It never leaves your Mac.
- **forecastDays** — how far ahead to report the review forecast.
- **minSecondsBetweenPushes** — debounce. A push happens after an answer at most this often; the end
  of a review session and a sync always push regardless.
- **showErrors** — show a tooltip when a push fails. Worth leaving on until it's working.
