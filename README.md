# Harness — Weekly Promo Scraper + On-Demand Bot

A Dart CLI program that searches for the latest **Makanan** (food),
**Minuman** (drinks, including coffee), **Jajanan** (snacks), and
**Lifestyle** promos/deals in Indonesia, summarizes them into structured
data using Genkit + Gemini (free tier) — including cross-source
deduplication, dead-link filtering, a social media "buzz" signal, and
big-brand prioritization — then sends the result to Telegram. Designed to
run as a lightweight AOT binary on a low-resource device (e.g. an
Armbian-based STB with 2GB RAM).

> Note: while the codebase, comments, and Gemini prompts are all in
> English, the actual content delivered to Telegram (promo details, bot
> replies, category labels) is intentionally kept in **Bahasa Indonesia**,
> since that's the target audience for the results.

## Key design choices

- **SerpApi as a Genkit tool, not a manual pre-fetch.** Gemini decides its
  own search queries via tool calling and may search multiple times if
  needed, instead of us fetching a fixed batch of results up front. See
  [genkit.dev/docs/js/tool-calling](https://genkit.dev/docs/js/tool-calling/)
  and section 8 below for why this required splitting extraction into two
  separate `generate()` calls.
- **Structured output via `schemantic`**, so Gemini's response is
  type-checked against a schema rather than just asked nicely via prompt.
- **Dead link filtering.** Every promo's source link is checked for
  reachability before being shown — unreachable links mean the whole promo
  entry is dropped, not just the link.
- **Social buzz signal.** Each promo is checked against Instagram, TikTok,
  Facebook, YouTube, X, and Threads to gauge how much the brand is being
  talked about.

## Project structure

```
harness/
├── bin/
│   ├── harness.dart               # weekly cron entry point
│   └── bot_listener.dart          # on-demand bot entry point (separate process)
├── lib/
│   ├── config.dart                # .env / environment variable loader
│   ├── core/
│   │   └── promo_orchestrator.dart # main orchestration logic
│   ├── flows/
│   │   ├── promo_flow.dart        # Genkit flow: tool registration + Gemini extraction
│   │   └── promo_schema.dart      # output & tool-input schemas (schemantic)
│   ├── models/
│   │   └── promo.dart             # Promo data model
│   ├── services/
│   │   ├── serpapi_client.dart    # SerpApi HTTP wrapper (used via the Genkit tool)
│   │   ├── social_buzz_checker.dart # "how much is this being talked about" signal
│   │   ├── link_validator.dart    # drops promos with unreachable source links
│   │   └── telegram_notify.dart   # formats & sends results to Telegram
│   └── storage/
│       └── promo_storage.dart     # saves weekly JSON history
├── .env.example
├── .gitignore
├── LICENSE
├── pubspec.yaml
└── README.md
```

## 1. Initial setup (on your dev machine first)

```bash
cd harness
dart pub get
dart run build_runner build --delete-conflicting-outputs
cp .env.example .env
```

The `build_runner` command above is **required** (and must be re-run
whenever you change `lib/flows/promo_schema.dart`) — it generates
`lib/flows/promo_schema.g.dart`, containing the concrete schema
implementation used to force Gemini's responses into the structure you
defined. The project will not compile without this generated file.

Fill in `.env` with:
- `GEMINI_API_KEY` — free from [Google AI Studio](https://aistudio.google.com/apikey), no credit card needed
- `SERPAPI_KEY` — from your [serpapi.com](https://serpapi.com/manage-api-key) dashboard
- `TG_BOT_TOKEN` — your Telegram bot token (via `@BotFather`)
- `TG_CHAT_ID` — target chat ID. To find it: send any message to the bot, then open `https://api.telegram.org/bot<TOKEN>/getUpdates` and look for `"chat":{"id": ...}`
- `REGION`, `ENABLE_BUZZ_CHECK`, `ENABLE_LINK_VALIDATION` — all optional, sensible defaults already set (see sections 6-9)

## 2. Test run on your dev machine

```bash
dart run bin/harness.dart
```

Check that the promo message arrives on Telegram and that a JSON file was
saved under `OUTPUT_DIR` (default `./harness-data`, inside the project
folder itself; overridable via `.env`).

## 3. Compile to an AOT executable (important for a 2GB RAM device)

Make sure `dart run build_runner build --delete-conflicting-outputs` from
step 1 has already run successfully (check that
`lib/flows/promo_schema.g.dart` exists) before compiling.

Don't run this via `dart run` on the STB — the Dart VM overhead is
noticeable on such a small device. Compile to native binaries first (two
separate binaries, one per entry point):

```bash
dart compile exe bin/harness.dart -o harness_promo
dart compile exe bin/bot_listener.dart -o bot_listener
```

Copy both binaries to the STB, in the same working folder, e.g.
`/home/pi/harness/`. Also copy `.env` to that same folder on the STB
(never commit `.env` to git).

## 4. Set up the weekly cron job on Armbian

```bash
crontab -e
```

Add this line (runs every Wednesday at 08:00):

```
0 8 * * 3 cd /home/pi/harness && ./harness_promo >> /home/pi/harness/log.txt 2>&1
```

The `cd` before the command matters — it's how the program finds `.env`
in the same folder (the `.env` loader looks for the file relative to the
working directory).

## 5. Check the logs

```bash
tail -f /home/pi/harness/log.txt
```

If something fails (SerpApi error, Gemini error, etc.), the program also
sends a short error notification to Telegram automatically, so you don't
need to check the log manually every week — just watch for an error
notification.

## 6. Categories & search region

**Category taxonomy:**

```
F&B
├── Makanan   (food)
├── Minuman   (drinks, including coffee)
└── Jajanan   (snacks)
Lifestyle
```

Each sub-category is searched & extracted separately (its own query hint &
Gemini prompt), then displayed on Telegram grouped under its parent
category (F&B with 3 sub-sections, Lifestyle as one).

**Result quality per sub-category**, enforced via prompt instructions to
Gemini (in `lib/flows/promo_flow.dart`) plus safety nets in code:
- **Cross-source deduplication**: the same promo found via multiple links is merged into one entry.
- **Link accuracy**: the saved source link must genuinely discuss that specific promo, not a generic link.
- **Big-brand priority**: promos from large, well-known merchants are prioritized.
- **Max 10 promos** per sub-category (enforced via prompt & `.take(10)` in code).

**Weekly search region** (cron) is set via `REGION`, default
`Jabodetabek`:

```
REGION=Jabodetabek
```

## 7. Bot listener (on-demand, SEPARATE from cron)

Besides the automatic weekly summary, `bin/bot_listener.dart` runs
**continuously** and waits for you to send a Telegram message to search
promos for a specific location, any time:

```
/promo Bandung
/promo Surabaya fnb
/promo Malang minuman
/help
```

### Why separate from cron?

Cron is great for scheduled tasks, but not for "wait for an incoming
message" — the bot listener needs a long-running process to respond
immediately once you send a command, rather than waiting for the next
cron cycle.

### How to run the bot listener on the STB

Run it as a background process that survives an SSH logout. Two options
on Armbian:

**Option A — systemd service (recommended, auto-restarts on crash):**

Create `/etc/systemd/system/harness-bot.service`:

```ini
[Unit]
Description=Harness Promo Bot Listener
After=network.target

[Service]
Type=simple
WorkingDirectory=/home/pi/harness
ExecStart=/home/pi/harness/bot_listener
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now harness-bot
sudo systemctl status harness-bot   # check status
journalctl -u harness-bot -f        # follow live logs
```

**Option B — manual nohup (simpler, but no auto-restart on reboot):**

```bash
cd /home/pi/harness
nohup ./bot_listener >> bot_listener.log 2>&1 &
```

### Important notes

- The bot listener **never touches** the weekly cron schedule — both run
  independently; an on-demand request never delays or interferes with the
  automatic weekly summary, and vice versa.
- `.bot_offset` is created automatically to track the last processed
  message, so a restarted bot listener doesn't reprocess old messages.
- The bot only responds to messages from the configured `TG_CHAT_ID` —
  messages from other chats are silently ignored.

## 8. Architecture: SerpApi as a Genkit tool + two-phase generation

Previously, our code called SerpApi first with a fixed query, then stuffed
the raw results into a Gemini prompt for summarizing. Now it's inverted:
SerpApi is registered as a **tool** that Gemini calls itself.

**Why split into TWO `generate()` calls, not one:**
Combining tool calling (`toolNames`) with structured output
(`outputSchema`) in a single call is **not supported by the Gemini API
itself**. The error is explicit: *"Function calling with a response mime
type: 'application/json' is unsupported"*. So it has to be split:

- **PHASE 1 (research)** — tool calling enabled (`toolNames: ['searchPromo']`), Gemini is free to call the `searchPromo` tool multiple times with different keywords, final answer is free-form text (not JSON).
- **PHASE 2 (structuring)** — no tools, only `outputSchema: PromoExtractionResult.$schema` — the sole job here is turning phase 1's text into structured data. The prompt explicitly forbids adding/inventing new information at this stage — pure reformatting.

**How the `searchPromo` tool works** (in `lib/flows/promo_flow.dart`):
```dart
_ai.defineTool(
  name: 'searchPromo',
  description: 'Searches Google for the latest promos/discounts...',
  inputSchema: SearchPromoInput.$schema,
  fn: (input, _) async {
    final results = await _serpapi.search(input.query, maxResults: 10);
    // ...formatted as text, returned to Gemini
  },
);
```

Phase 1's prompt gives a **suggested starting keyword** (from
`categorySearchHints` in `lib/core/promo_orchestrator.dart`), but Gemini is
free to call `searchPromo` repeatedly with other keywords if it thinks the
first result is insufficient — e.g. trying to include a well-known big
brand name popular in that category, or a variation of promo-related
terms. Search queries themselves are written in Bahasa Indonesia (per the
prompt instructions), since we're searching for Indonesian-language promo
content.

**Practical consequences of this two-phase design:**
- **2x Gemini calls per sub-category** (not 1x) — for 4 sub-categories/week, that's 8 Gemini calls per week (still well within `gemini-2.5-flash`'s free tier limits).
- Phase 1 itself may call the `searchPromo` tool several times (Gemini decides), so the total SerpApi calls per sub-category isn't fixed — it depends on how much Gemini feels it needs to dig further.
- If you need a hard, predictable call count later, the simplest option is reverting to the old pattern (manual pre-fetch, no tool calling) — but that sacrifices the adaptive behavior that motivated this change in the first place.

**Known open question:** how many times Gemini is allowed to call a tool
before stopping (called `maxTurns` in JS Genkit) hasn't been confirmed by
name/support in Genkit Dart, so it's intentionally left unset — relying on
the library's default. If Gemini ends up calling the tool too many times
(burning SerpApi quota) or stops too early, this is the first parameter to
check.

## 9. Dead link filtering

Before a promo is shown, its `sourceLink` is checked for reachability
(`lib/services/link_validator.dart`). If the link fails, the **entire
promo** is dropped — not just the link.

**How it works:**
- Tries a `HEAD` request first (cheaper), falls back to `GET` if `HEAD`
  fails outright or returns a non-acceptable status (some servers reject
  `HEAD` but serve `GET` fine).
- A browser-like `User-Agent` header is sent, to reduce false negatives
  from sites that block requests with missing/unusual User-Agent headers.
- Status codes 2xx/3xx are accepted. `403` is also accepted, since many
  sites (especially social platforms) block non-browser requests with 403
  even though the content genuinely exists — treating 403 as "invalid"
  would create too many false negatives.
- Checks run in parallel (`Future.wait`) across all promos in a batch, so
  this doesn't add a large linear delay.

**If this causes too many false negatives** (e.g. your network is behind
a firewall/proxy that blocks outgoing requests to certain sites), disable
it via `.env`:
```
ENABLE_LINK_VALIDATION=false
```

## 10. Social buzz signal

Every promo that passes extraction is checked again via SerpApi to see how
much its brand is being talked about on **Instagram, TikTok, Facebook,
YouTube, X, and Threads** — shown on Telegram as:

```
📊 🔥 Sangat ramai dibicarakan (Instagram, TikTok, X)
```

**How it works & its limitations (important to understand):**
- The query used is `"<merchant name>" promo (site:instagram.com OR site:tiktok.com OR ...)` — ONE combined query covering all six platforms at once, not 6 separate queries. This is a deliberate cost decision: 6 separate queries per promo x ~40 promos/week = 240 extra SerpApi calls/week, versus ~40 extra calls/week with the combined approach.
- Consequence: this signal shows **which platforms mention the brand**, not an exact count per platform.
- The query searches for the merchant name + the word "promo" generally, not the exact extracted `promoTitle` text — because Gemini's summarized wording rarely matches real social captions word-for-word. So this is a signal for how much the **brand** is being discussed in relation to promos, not confirmation that this exact promo is what's trending.
- Score labels: 0 results = "Belum ramai dibicarakan", 1-3 = "Mulai dibicarakan", 4-7 = "Cukup ramai", 8+ = "Sangat ramai 🔥".
- Buzz checks run in parallel per batch, so they don't add a large linear delay.

**If SerpApi quota becomes a problem**, disable via `.env`:
```
ENABLE_BUZZ_CHECK=false
```
Promos are still sent as usual, just without the buzz signal line.

**If you need an exact per-platform breakdown** later (not just "which
platforms"), that requires upgrading to separate per-platform queries —
automatically 6x the SerpApi cost per promo, so weigh that against your
SerpApi quota/budget first.

## Further development ideas (optional)

- **Base search hints per category**: in `lib/core/promo_orchestrator.dart`, the `categorySearchHints` constant. Adjust keywords as needed (e.g. add favorite brands).
- **Structured output**: promo extraction uses `outputSchema` from the `schemantic` package (see `lib/flows/promo_schema.dart`), forcing Gemini to follow the defined data structure at the API level. If you change fields in `promo_schema.dart`, remember to re-run:
  ```bash
  dart run build_runner build --delete-conflicting-outputs
  ```
- **Gemini free tier rate limits**: the weekly summary plus a handful of on-demand requests per week is still well below the free tier limit.
- **Automatic retries**: for more resilience against transient network errors, Genkit Dart has `RetryMiddleware` that can be added to the plugin configuration.
- **Cross-week deduplication**: history is already saved in `harness-data/*.json`, but nothing currently reads it back to avoid re-sending a promo that's still running from a previous week — this would be a natural next step if repeat notifications become annoying.
