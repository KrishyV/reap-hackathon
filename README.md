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

One-time payment setup: open **/setup**, start an enrollment, and enter a test card on Reap's hosted page (OTP `456789`). This must be done in a real browser. The enrollment id is saved to `data/state.json` (or set `REAP_ENROLLMENT_ID`).

Optional env: `OPENAI_MODEL` (default `gpt-4o-mini`), `RETURN_URL`, `SIMULATE_CHECKOUT` (default `true` in sandbox; skips the hosted approval step), `REAP_WEBHOOK_SECRET` (enables signature verification on `POST /webhooks/reap`).

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

## Never committed

`.env`, `instructions.md`, `data/*.json`, `vendor/`.
