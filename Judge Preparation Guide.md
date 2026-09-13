# Judge Preparation Guide

## 1. 30-60 SECOND ELEVATOR PITCH

"Buy or Wait?" is a Ruby-based financial decision agent for the HackerRank Orchestrate hackathon. Given a user's purchase request, it reconstructs their financial state from structured profiles and events, uses an LLM only to extract facts from messages and images (never for decisions), then runs a deterministic 90-day cash-flow forecast in BigDecimal. A payment planner selects the safest affordable plan, a spending-change planner optionally proposes flexible cuts, and a hard OutputValidator rejects any inconsistent output before writing `output.csv`. It processed all 250 requests with zero validation failures, and every decision is reproducible run to run.

## 2. THE CORE PROBLEM

**What "Buy or Wait?" solves:** For every purchase request, the system must decide whether to pay in full, pay partially, use installments, wait, or not proceed — while keeping the user's balance above their minimum safe threshold throughout a 90-day horizon.

**Why ordinary LLM prompting is not enough:** A raw LLM doesn't see the user's financial profile, pending transactions, minimum balance, schedule, or currencies. It also hallucinates amounts, invents income, and cannot simulate cash flow. In this implementation, the LLM is constrained: it only emits structured extraction results that are then validated by deterministic Ruby code. All financial math is deterministic BigDecimal.

**Why financial safety needs deterministic calculations:** Money math must be exact (BigDecimal, never Float), dates are deterministic (no `Date.today`/`Time.now`), and payment plans are rank-ordered by fixed criteria (on-time → total cost → earlier start → fewer payments). This guarantees the same input always yields the same safe output.

## 3. ARCHITECTURE

```
User Request
↓
Dataset + Financial Profile (dataset/*.csv)
↓
UnstructuredContext (relevant messages + images)
↓
LLM extraction when necessary (image amounts, message facts)  ← Mock/Gemini/OpenAI
↓
Deterministic Ruby Financial Engine (BigDecimal cash-flow)
↓
90-day cash-flow forecast
↓
Payment Planner (plan candidates vs. forecast)
↓
Spending Change Planner (flexible-only cuts)
↓
Decision Explanation
↓
Output Validator (hard rules)
↓
Final output.csv
```

- **Dataset/Financial Profile:** Loads all CSVs via `dataset.rb`, keyed by `user_id`/`request_id`.
- **UnstructuredContext:** Selects messages/images relevant to each request.
- **LLM extraction:** `image_amount_extractor.rb` (blank amounts from images) and `message_fact_extractor.rb` (financial facts from text). Both have Mock/Gemini/OpenAI providers. Results validated before use.
- **Financial Engine:** `financial_engine.rb` runs a 90-day forecast, computes `amount_safe_to_pay` and `earliest_date_for_full_payment`.
- **Payment Planner:** `payment_planner.rb` builds plan candidates from request payment options.
- **Spending Change Planner:** `spending_changes.rb` proposes `stop:`/`reduce_to:` actions for flexible recurring expenses only.
- **Decision Explanation:** `decision_explanation.rb` produces grounded text.
- **Output Validator:** `output_validator.rb` enforces schema, enums, bounds, feasibility, and cross-field consistency.
- **Pipeline:** `pipeline.rb` orchestrates: load → context → cache → per-request → validate → verify_counts! → write.

## 4. WHY RUBY?

Ruby's standard library covers this challenge well:

- **CSV:** `CSV.read`/`CSV.foreach` load all dataset files natively; no extra deps.
- **BigDecimal:** exact money arithmetic via `Money`/`MoneyDSL`; strict avoidance of `Float`.
- **Date:** deterministic date math (`+`/`<<`/`>>` for recurrence, settlement dates); `Date.today`/`Time.now` are forbidden by Stage 2-4 checks.
- **JSON:** `JSON.parse` for LLM responses (Gemini/OpenAI), so JSON parse-errors are handled explicitly.
- **Deterministic logic:** single-threaded pipeline, sorted event processing, no concurrency randomness.

The challenge allows any language (AGENTS.md §6.6), and Ruby's expressiveness + BigDecimal/CSV/Date/Date stdlib fit the deterministic financial engine cleanly.

## 5. LLM ROLE VS DETERMINISTIC ROLE

- **What the LLM is allowed to do:**
  - Extract numeric amounts from images (via Vision provider).
  - Extract structured facts from messages (salary confirmations, cancellations, amendments, scheduled payments) as JSON, via a strict schema-validated struct (`MessageFactExtractor::Fact`).

- **What the LLM is NOT trusted to do:**
  - Cannot override `related_event_id` from CSV (authoritative).
  - Cannot override `source_type` or `sent_at` (taken from `message_row`).
  - Cannot invent new `event_id`s when `related_event_id` is blank.
  - Cannot create income from non-employer sources.
  - Cannot choose, rank, or validate payment plans.
  - Cannot perform any financial calculation.

- **How extracted facts are validated:** Pure-Ruby validators reject non-numeric/negative amounts, bad dates, unknown event IDs, unsupported fact types, and malformed JSON. Prompt injection is treated as untrusted content and rejected by the validators.

- **How Ruby makes the final decision:** `FinancialEngine.evaluate_request` runs the forecast; `PaymentPlanner.select_plan` ranks candidates; `OutputValidator.validate` blocks any invalid output; `Pipeline.verify_counts!` ensures request/output row counts.

- **Strong answer to "Why not just ask an LLM whether the user can afford the purchase?":** An LLM cannot see the user's `minimum_balance_to_keep`, pending transactions, scheduled salary dates, FX rate, or currency — all of which exist in CSVs. It also hallucinates. In this design, the LLM only extracts untrusted evidence that Ruby validates and reasons over deterministically. Every decision is checked against hard rules (balance never falls below minimum, plan matches options, partial sum equals requested, etc.), none of which an LLM prompt alone could guarantee.

## 6. MULTIMODAL / IMAGE HANDLING

- `dataset/images.csv` maps `event_id → image_id → media/images/<image_id>.png`.
- Only events with blank `amount` are routed to image extraction (16 events total detected in Stage 3).
- `image_amount_extractor.rb` calls the Vision provider (Mock/Gemini/OpenAI) with the image, parses a JSON response, and validates:
  - `amount` is numeric, positive.
  - `currency` is supported.
  - `event_id` matches the linked event.
  - `confidence` is in range.
- Image-derived amounts are **untrusted until validated** — a parser rejects null/zero/negative/ambiguous text, and **the engine emits a warning and excludes the event rather than treating failure as zero**.
- On failure, `amount = nil` and an `extraction_warnings` entry is logged (Stage 3 TEST 7).

## 7. MESSAGE / TEXT EXTRACTION

- `message_fact_extractor.rb` calls the message LLM provider with strict schema, returning `MessageFact` structs.
- **Authoritative `related_event_id`:** Taken from `messages.csv`. If the LLM omits it, it's inherited from the CSV link; if the LLM supplies a conflicting `event_id`, the fact is **rejected** (Stage 6 TEST 21, TEST 22).
- **`source_type` and `sent_at`:** Taken from `message_row`, not from LLM output (Stage 6 TEST 23, TEST 24).
- **Conflict resolution precedence** (per `resolve_conflicts`):
  1. Cancellation first.
  2. Newer record from the same source.
  3. Settled event beats forecast.
  4. Safer interpretation (lower salary wins).
- **Cancellations beat amendments for same event** (Stage 6 TEST 28).
- **Prevented LLM hallucinations:**
  - `salary_confirmation` from non-employer `source_type` is rejected (Stage 6 TEST 25).
  - `scheduled_payment` matching an existing sched_event is not double-counted (Stage 6 TEST 29).
  - Model-invented `event_id`s are rejected (Stage 6 TEST 22).

## 8. AFFORDABILITY ENGINE

- **`amount_safe_to_pay`:** Largest amount safe to pay on `request_date` (before optional spending changes) while keeping projected balance ≥ `minimum_balance_to_keep`, considering pending debits and essential expenses.
- **Minimum balance:** Reserved after every projected essential expense and payment in any recommended plan.
- **Essential expenses:** Detected via profile `protected`/`adjustable`; forecast conservatively.
- **90-day forecast:** Horizon; earlier events first; recurrence detection via `recurrence.rb`.
- **Scheduled transactions:** Counted on settlement dates.
- **Recurring expenses/income:** Detected via recurrence module (genuine streams preserved; sporadic 2-occurrence "fuel" and ended salary rejected — Stage 2 TEST 2-4).
- **Pending credits:** Not counted until settled.
- **Failed/cancelled transactions:** Ignored (Stage 4 boundary checks).
- **Unrealized investments:** Treated as non-cash; not available.
- **Currency/FX:** Fixed dated `exchange_rates.csv`, `from_currency → to_currency` for settlement date; amounts in user's `home_currency`.

## 9. PAYMENT PLANNING

- **`full_payment`:** Pay `requested_amount` on `request_date`; status `affordable_now`.
- **`partial_payment`:** Two payments: `amount_safe_to_pay` today, remainder on `earliest_date_for_full_payment` (≤ `desired_completion_date`); status `affordable_with_plan`.
- **`installments`:** Chronological payments matching a supplied payment option exactly.
- **`wait`:** Afford today < requested, but full payment becomes safe later (≤ deadline); status `affordable_later`.
- **`not_recommended`:** No safe plan; status `not_affordable`.
- **Ranking/tie-breaking:** on-time before missing deadline; then lower total cost; then earlier start; then fewer payments. Deterministic: identical over 100 runs (Stage 7 TEST 12). This ensures reproducible, defensible plans.

## 10. SPENDING CHANGES

- Proposes up to 3 `stop:<event_id>` / `reduce_to:<event_id>:<new_amount>` actions.
- **Eligible only:** flexible recurring expenses in categories the user permits.
- **Never changed:** essential/fixed/protected expenses, one-off expenses, nonexistent event IDs.
- `stop`/`reduce_to` mutually exclusive per event; reduction amount must be strictly lower.
- Safety re-checked after changes; insufficient changes rejected (Stage 7 TEST 10).

## 11. SAFETY / VALIDATION

`OutputValidator` enforces (Stage 8, 25 tests):
- Required 8 columns, exact order.
- Enum constraints on `affordability_status`/`recommended_payment_method`.
- `BigDecimal` amounts; `0 ≤ amount_safe_to_pay ≤ requested_amount`.
- `payment_plan`: `YYYY-MM-DD:amount` entries, chronological, `|` separator, or `none`.
- `partial_payment` sums to `requested_amount`, exactly 2 entries.
- Installments match a supplied payment option.
- `spending_changes_needed`: ≤3, unique event IDs, valid `stop:`/`reduce_to:` syntax.
- Cross-field consistency: `affordable_now ↔ full_payment`, `affordable_later ↔ wait`, `not_recommended ↔ none`, `wait ↔ earliest > request_date`, `full_payment ↔ amount_safe ≥ requested`.

**Likely judge questions:**

- **Can the LLM hallucinate money?**  
  A) No — the LLM only extracts facts via validated structs; it never outputs amounts directly.  
  B) Even if it tries, pure-Ruby validators reject non-numeric/bad amounts, and the engine never uses raw LLM numbers.

- **Can the LLM change an event ID?**  
  A) No — `related_event_id` from CSV is authoritative.  
  B) Fact validation rejects any LLM-supplied `event_id` conflicting with the CSV, or invented IDs when the CSV link is blank (Stage 6 TEST 21-22).

- **What if an image amount is missing?**  
  A) That event is excluded with a warning; amount is nil, never zero.

- **What if two messages conflict?**  
  A) Cancellation → newer-same-source → settled → safer interpretation.  
  B) Deterministic `resolve_conflicts` with explicit precedence.

- **What if the user cannot afford?**  
  A) `not_affordable` + `not_recommended`, `spending_changes=none`, `earliest_date_for_full_payment` empty.

- **How guarantee payment plans stay safe?**  
  A) The forecast checks balance ≥ min after every step.  
  B) `PaymentPlanner` only emits candidates proven safe against the forecast; validator blocks infeasible plans.

- **Can the system use future salary?**  
  A) Only scheduled, confirmed salary on its settlement date.  
  B) No unscheduled/bonus/forecast income; Stage 2 TEST 1.

- **Currencies?**  
  A) Fixed dated `exchange_rates.csv` per settlement date.  
  B) All math in `home_currency`; `from → to` direction.

- **BigDecimal?**  
  A) Exact money; no float drift.

- **Prompt injection?**  
  A) Treated as untrusted text; validators reject non-numeric injection; Stage 3 TEST 8.

- **LLM provider fails?**  
  A) Extraction fails → event excluded with warning, not zero.

- **Live exchange rates?**  
  A) No — fixed rates only.

## 12. DEMO WALKTHROUGH

- `request_26` (IDR 15,656,000): **affordable_now**, full_payment, pay 15,656,000 on request date. User has sufficient current + near-future cash to cover full amount immediately while keeping minimum balance.
- `request_272` (IDR 13,585,000): **affordable_with_plan**, installments, 3 payments across ~3 months. Today's `amount_safe_to_pay` < requested, but a supplied installment option spreads cost safely within forecast.
- `request_29` (ZAR 51,524): **not_affordable**, not_recommended. Safe amount today ~256.36, no plan reaches full amount by deadline → user should not proceed.

## 13. CHALLENGE REQUIREMENTS MAPPING

| Requirement | Where | How |
|---|---|---|
| Read dataset files | `code/lib/dataset.rb` | Loads all CSVs via `Dataset` |
| One prediction per request | `code/lib/pipeline.rb` | 250 requests → 250 rows, verified by `verify_counts!` |
| Exact 8 columns/order | `code/lib/pipeline.rb`, `output_validator.rb` | Schema + validator |
| 0 ≤ amount_safe ≤ requested | `output_validator.rb` | Bounds checks |
| Installments match options | `code/lib/payment_planner.rb` | Validates each option |
| Flexible-only spending changes | `code/lib/spending_changes.rb` | Filters eligible streams |
| Deterministic | `financial_engine.rb`, `recurrence.rb` | No Float, no Date.today (Stage 2/4 checks) |
| Secrets from env | `pipeline.rb` resolve_providers | `.env`, no hardcoded keys |
| README + usage_report | `README.md`, `code/evaluation/usage_report.md` | — |
| Output validation | `output_validator.rb`, `verify_stage8.rb`, `verify_stage9.rb` | 25+ tests |
| Chat transcript | `log.txt` (gitignored) | — |

## 14. WHAT MAKES THIS PROJECT DIFFERENT

1. **LLM as extraction layer, not decision maker** — financial logic is deterministic Ruby.
2. **Deterministic BigDecimal engine** — no float, no Date.today; reproducible results.
3. **Safety-first 90-day cash-flow simulation** — balance ≥ minimum at every step.
4. **Explicit conflict-resolution precedence** — cancellation > newer > settled > safer.
5. **Hard OutputValidator** — rejects any inconsistent/infeasible output before writing.

## 15. LIMITATIONS

1. Final run used mock providers, not real Gemini — results reflect mock extraction logic.
2. `code.zip` should contain root-level `evaluation/usage_report.md` (currently under `code/evaluation/`).
3. 90-day fixed forecast horizon; no longer horizons.
4. Image extraction tested via mock only; no real vision model validation.
5. Fixed exchange rates (no real-time FX).

## 16. 2-MINUTE PRESENTATION SCRIPT

"Hi. I'm presenting 'Buy or Wait?', a Ruby financial agent for HackerRank Orchestrate. For each of 250 purchase requests, the system reconstructs the user's financial state from profiles and events, forecasts 90 days of cash flow in exact BigDecimal math, and selects the safest affordable payment plan. The LLM is used only to extract facts from messages and images — it never makes money decisions. Extracted facts are validated by pure-Ruby parsers before use. Every output is checked by a hard validator that blocks inconsistent or infeasible plans. The result: 250 rows with zero validation failures, fully reproducible across runs. This is safer than asking an LLM to decide affordability, because the LLM can't see minimum balance, pending transactions, or currency rates — and it hallucinates. My engine sees all of it and can't."

## 17. 5-MINUTE TECHNICAL PRESENTATION SCRIPT

"The architecture flows: request → dataset+financial profile → unstructured context → LLM extraction when needed → deterministic Ruby engine → 90-day forecast → payment planner → spending change planner → output validator → output.csv. Three Ruby stdlib pillars: BigDecimal for exact money math, CSV for all data loading, and Date for deterministic scheduling. The LLM role is strictly bounded: it emits structured Fact structs (amount, currency, date, status, fact_type) parsed from JSON. If JSON is malformed or any field is invalid, the fact is rejected. Critically, the LLM cannot override `related_event_id`, `source_type`, or `sent_at` — those come from the CSV message_row. Conflict resolution precedence is cancellation first, then newer-same-source, then settled-over-pending, then the safest interpretation (lower salary wins). Image-derived amounts are untrusted: on extraction failure, the event is excluded with a warning rather than treated as zero. The financial engine computes `amount_safe_to_pay` on request_date before optional changes, reserves minimum balance at every step, ignores pending credits until settled, and ignores unrealized investments entirely. Payment planning rank-orders feasible candidates: on-time > lower total cost > earlier start > fewer payments, deterministic across 100 runs. Spending changes apply only to flexible recurring expenses, up to three, safety re-checked after each. Finally, OutputValidator enforces all hard rules before any row is written — schema, enums, bounds, plan feasibility, partial sum = requested, installments match a supplied option, and cross-field consistency. The final run processed all 250 requests with zero validation failures."

## 18. RAPID-FIRE MOCK INTERVIEW

**Question 1:** Why didn't you just ask an LLM whether the user can afford the purchase? Give me your 30-second answer.

(After you answer, I'll grade it and ask Question 2.)