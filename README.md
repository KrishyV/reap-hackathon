# 🥟 Dumpling Bros · Agent Shopper

Tell an AI agent what you need and how much you'll spend. It plans the shopping list, compares real products across Reap merchant catalogs and shows you a basket to approve. It then issues a **single-use prepaid Reap virtual card loaded with exactly your budget** and checks out with every merchant through **Reap Agentic Payments**. When it's finished, the card is frozen.

> "I want to start Muay Thai. Suggest all the gear a beginner needs." · Budget **$250**
> → gloves, wraps, shin guards, shorts, mouthguard, bottle, bag from Forza Sports + Decathlon, **$238.17**

## Why it's safe to let an agent spend

The budget is enforced in four independent places:

| Layer | What enforces it |
|---|---|
| Planning | `Basket.fit` never proposes more than the budget. It first swaps to cheaper options, then drops the lowest-priority items, then re-adds any dropped item that still fits (property-tested). |
| Quote | Each merchant quote includes shipping and tax. If the quote goes over what's left, the agent drops the least important item and requotes. |
| Card | The card is funded with **exactly** the budget and has a **lifetime spend cap = budget**, a **max-charges = number of merchants** limit, online-only use, and risky MCCs (gambling, crypto, cash) blocked. Reap's card network declines anything over the cap. |
| Ledger | `BudgetGuard` holds every order's amount on the card *before* checkout. A declined hold means no checkout. A completed checkout captures the amount; a failed one releases it. Invariant: `spent + held ≤ budget`. |

Every money-moving POST uses a **deterministic idempotency key**, so retries can never double-charge. The card is frozen in an `ensure` block, so it's frozen even when something crashes.

## Run it

```bash
cp .env.example .env              # fill REAP_API_KEY, OPENAI_API_KEY
bundle config set path vendor/bundle && bundle install
bundle exec rackup -p 4567        # http://127.0.0.1:4567
bundle exec rspec                 # property-based + unit tests
```

One-time card setup at **/setup** (about 30 seconds, done once per install):

1. **Get a secure card link.** It uses your saved email, and every card is filed under one stable owner ID in `data/state.json`.
2. **Add the card on Reap's page**, either on this computer or by scanning the QR code with your phone. Sandbox test cards are listed on the page with tap-to-copy (e.g. `4622 9431 2313 7797`, CVC `640`, exp `12/27`, OTP `456789`).
3. **Confirm with a passkey.** Visa requires a one-time Face ID / Touch ID / device-PIN passkey before an agent can use a card. Neither Reap nor this app can skip it.
4. The page polls Reap and switches to **Ready** by itself, with no reload needed.

Notes:
- **Mac Safari** blocks Visa's embedded passkey step ("Authentication Failed"). `/setup` detects it and points you to the QR code or another browser.
- Cards are reused: if an earlier card is still `ACTIVE`, `/setup` switches back to it instead of asking again.
- **Other machines:** paste an existing enrollment ID under "Already added a card elsewhere?", or pin one with `REAP_ENROLLMENT_ID`. Any card added with the same Reap API key works.

Optional env: `OPENAI_MODEL` (default `gpt-4o-mini`), `RETURN_URL`, `SIMULATE_CHECKOUT` (default `true` in sandbox; skips the hosted approval step), `REAP_WEBHOOK_SECRET` (enables signature verification on `POST /webhooks/reap`).

**Fastest path (demo):** the first purchase saves your shipping details. After that, keep **Autopilot** on: type a goal, tap a budget chip, press Go, and the agent plans, checks the basket against the budget and buys without a review step.

## International shopping

Can Reap pay foreign merchants? **Yes, but it doesn't publish exchange rates.** The card bills in USD. When a merchant charges in GBP or EUR, Reap converts at authorization (`originalCurrency` → `currency` at `conversionRate`) and adds an `FX_MARKUP` fee (basis points, from `GET /fees/effective`; **51 bps** on our sandbox account). To keep "never over budget" *before* paying, the agent estimates:

- **Rates:** [Frankfurter](https://github.com/lineofflight/frankfurter) (ECB reference rates; MIT-licensed, keyless, self-hostable via `FX_URL`). If it's unreachable, a bundled ECB snapshot (`lib/shopper/fx_snapshot.json`) is used with an extra drift buffer.
- **Hold** = native quote × rate × (1 + FX markup + buffer), rounded **up**. **Capture** = native final × rate × (1 + markup), capped at the hold. Cards, holds and the budget guard stay in USD.
- The basket uses the same conservative USD estimates and shows `£30.00 ≈ $41.00`. A merchant whose currency can't be priced is never held or checked out.
- Reap's search `context.currency` acts as a **filter**, not a conversion: merchants that don't sell in that currency simply don't appear. Choose a **Ship to** country to shop that market.

Env: `FX_MARKUP_BPS` (default 150, overridden live by the account's real fee), `FX_BUFFER_BPS` (100), `FX_TTL_SECONDS` (3600), `FX_URL`.

## Merchants

Reap has no merchant-listing endpoint, so we surveyed the sandbox catalog (86 merchants across 66 queries). The home page shows a curated strip (`lib/shopper/merchants.json`): Kith, Alo Yoga, True Classic, Thursday Boots, Bluemercury, Death Wish Coffee, Harney & Sons, Misen, Baronfig, Headphones.com and more.

## Logging & introspection (for agentic debugging)

Every layer emits structured events (`run.*`, `research.*`, `llm.*`, `reap.request/response`, `agentic.*`, `card.*`, `guard.*`, `order.*`, `fx.*`, `basket.*`, `http.request`, `webhook.*`). Each event carries `run_id`, `request_id`, `merchant` and `phase` context, which follows work into background threads. **Logs are unredacted by design: this is a sandbox-only app.**

- stderr: human-readable at `LOG_LEVEL` (info), or `LOG_FORMAT=json`
- `log/shopper.jsonl`: every event at `LOG_FILE_LEVEL` (debug), including full Reap/OpenAI request and response bodies
- localhost-only endpoints (disable with `DEBUG_ENDPOINTS=false`): `/debug/logs?run_id=&request_id=&level=&event=&since=&limit=`, `/debug/runs`, `/debug/runs/:id` (state + full trace), `/debug/config`, `/debug/fx?currencies=GBP,EUR&amount=100`

```bash
curl -s '127.0.0.1:4567/debug/runs/<id>' | jq '.summary'
jq -c 'select(.run_id=="<id>") | [.seq,.event,.msg]' log/shopper.jsonl
```

## Demo script (3 min)

1. **Problem (20s):** Agents can shop, but nobody hands an agent their real card. We give the agent a disposable card that physically can't overspend.
2. **Ask (30s):** Type the Muay Thai goal with a $250 budget. The live log shows the plan, parallel catalog searches and LLM ranking.
3. **Review (30s):** The basket shows priorities, alternatives per item and anything left out to fit the budget. Untick an item or switch to an alternative.
4. **Buy (60s):** The agent creates the cardholder, issues the card, loads exactly $250, locks it with the cap, charge limit, channel and MCC policies, then quotes each merchant with shipping and tax, holds, checks out and captures.
5. **Receipt (30s):** Orders, spent vs unspent, card 🧊 frozen. Click **Reveal** to show it's a real Reap card. **Orders** shows the history.
6. **Correctness (10s):** `bundle exec rspec` runs property tests: the basket never exceeds the budget, every hold is captured or released exactly once, and the card is always frozen.

## Architecture

```
app.rb (Sinatra)  ── Run state machine: planning → awaiting_review → purchasing → done/failed
 ├─ Researcher    ── Planner (OpenAI) → Reap product search (throttled, retried) → LLM rank → product details → Basket.fit
 ├─ Executor      ── PrepaidCards.provision → per merchant: quote → cheapest shipping → fit → hold → checkout → poll → capture/release → freeze
 ├─ Reap::Client  ── Bearer auth, Reap-Version, Idempotency-Key, retries on 408/425/429/5xx with the same key
 ├─ Store         ── data/*.json: enrollment, order history, webhook events
 └─ WebhookVerifier ── HMAC-SHA256 "t.body", 5-minute tolerance, constant-time compare
```

## Sandbox caveat (be upfront in the demo)

Agentic Payments currently only accepts `EXTERNAL` enrollments (`REAP_CARD` is "coming soon"), so the merchant charge goes to the enrolled card. The Reap prepaid card acts as the **budget authority**: each order is authorized on it (simulated card network) *before* checkout, and settled or reversed afterwards. Once Reap-card enrollment ships, the prepaid card becomes the payment method directly and the same guards still apply.

## Dependencies

Only Reap and OpenAI are integrated. Everything else is free and open source: Ruby gems (Sinatra, Rack, Puma, dotenv, rqrcode, prop_check, rspec, webmock: MIT or BSD-3-Clause), Frankfurter (MIT) for rates, and hand-written CSS/JS with no CDNs or fonts.

## Never committed

`.env`, `instructions.md`, `data/*.json`, `log/`, `vendor/`.
