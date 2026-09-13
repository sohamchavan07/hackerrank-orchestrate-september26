# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with this repository.

## TL;DR

- Language: Ruby. Entry point: `code/main.rb` → `ruby code/main.rb`.
- Goal: build a "Buy or Wait?" financial agent that writes `output.csv` (repo root) with one row per `request_id` in `dataset/requests.csv`.
- Tests live as `code/bin/verify_stageN.rb` scripts (run individually or in order).
- `AGENTS.md` is the binding project contract (logging, challenge rules, output schema); this file adds workflow + architecture.

## Common Commands

### Run the solution

```bash
ruby code/main.rb
```

Writes `output.csv` at the repo root via `Pipeline.default_output_path` (currently `File.join(Dataset::ROOT, 'output.csv')`).

### Run the verification scripts (the closest thing to a test suite — Stage 2 → 8)

```bash
ruby code/bin/verify_stage2.rb   # deterministic engine: recurrence, salary continuation, essential filter
ruby code/bin/verify_stage3.rb   # image amount extraction -> BigDecimal
ruby code/bin/verify_stage4.rb   # affordability + earliest date, regression across earlier stages
ruby code/bin/verify_stage5.rb   # payment method + plan selection
ruby code/bin/verify_stage6.rb   # LLM fact extraction from messages
ruby code/bin/verify_stage7.rb   # spending changes (stop/reduce, flexible-only)
ruby code/bin/verify_stage8.rb   # OutputValidator constraints
```

Run all, in order:

```bash
for s in 2 3 4 5 6 7 8; do ruby code/bin/verify_stage$s.rb; done
```

One-off debugging helper:

```bash
ruby code/bin/inspect_context.rb   # dumps per-request UnstructuredContext
```

### Environment (optional providers)

`code/main.rb` reads provider configuration from the environment. Defaults to mock providers (no external calls):

- `VISION_PROVIDER=mock|gemini|openai` (default `mock`)
- `VISION_MODEL=<model name>`
- `MESSAGE_PROVIDER=mock|gemini|openai` (default `mock`; falls back to `LLM_PROVIDER`)
- `GEMINI_API_KEY` / `OPENAI_API_KEY` as required by the chosen providers

No environment variables are required to run deterministically.

## Architecture

**LLM-assisted, deterministic-finance**

Ruby. All solution code lives under `code/`. `code/lib/*.rb` are the modules; nothing in `lib/` is a Rails/Sinatra app — it is a plain set of modules orchestrated by `Pipeline`.

```
DATASET
   │
   ┌─────────┴─────────┐
   │                   │
STRUCTURED         UNSTRUCTURED
   │                messages/images
   │                   │
   │              LLM / Vision
   │                   │
   └──────────┬────────┘
              ↓
      CANONICAL FACTS
              ↓
      FINANCIAL TIMELINE
              ↓
     CASH-FLOW ENGINE
              ↓
     CANDIDATE PLANS
              ↓
  DETERMINISTIC VALIDATOR
              ↓
      BEST VALID PLAN
              ↓
       output.csv
```

- **LLM/Vision Provider** (Stage 3 & 6 only): Extracts facts from unstructured data (messages, images)  
  → Never makes financial decisions, treats content as untrusted data  
  → Returns canonical facts (amounts, dates, statuses) via extraction cache  

- **Deterministic Financial Engine** (Stages 2, 4, 5, 7, 8, 9): Pure Ruby financial logic  
  → Reconstructs financial timeline from structured data + canonical facts  
  → Performs 90-day cash-flow simulation with BigDecimal precision  
  → Generates candidate payment plans based on forecast  
  → Validates all plans against safety constraints  
  → Selects best valid plan deterministically  

```
code/
├── main.rb                 # Entry point; delegates to Pipeline.run
├── lib/
│   ├── dataset.rb          # Loads all CSVs from Dataset::ROOT (dataset/)
│   ├── money.rb            # BigDecimal money helpers
│   ├── exchange_rates.rb   # Fixed dated FX rates ->_currency conversion
│   ├── recurrence.rb       # Recurring vs one-time event detection
│   ├── unstructured_context.rb   # Per-request message/image context (feeds LLM/Vision)
│   ├── financial_engine.rb       # 90-day balance forecast, amount_safe_to_pay, earliest_date_for_full_payment (deterministic)
│   ├── image_amount_extractor.rb # Blank-amount -> image -> extraction (LLM/Vision)  
│   ├── message_fact_extractor.rb # Message fact extraction + conflict resolution (LLM)
│   ├── payment_planner.rb        # Selects payment method + plan per problem rules (deterministic)
│   ├── spending_changes.rb       # stop:<event> / reduce_to:<event>:<amt> (flexible-only, deterministic)
│   ├── decision_explanation.rb   # Concise grounded explanation text (deterministic)
│   └── output_validator.rb       # Enforces schema, enums, bounds, plan feasibility (deterministic)
└── bin/verify_stage2.rb … verify_stage8.rb  # Stage-based verification scripts

### Data flow

1. `Pipeline.load_dataset` reads `requests`, `financial_profiles`, `financial_events`, `images`, `messages`, `request_payment_options` via `Dataset`, keyed by `user_id` / `request_id`.
2. `UnstructuredContext.build` builds a per-`request_id` context of relevant messages and images (input to LLM/Vision).
3. `Pipeline.resolve_providers` chooses mock or real (Gemini/OpenAI) vision/message providers. If mock or no unstructured context is needed, no external API calls are made.
4. Image and message extraction caches are built once (`build_image_cache`, `build_message_cache`), then reused per request.
5. For each request, `Pipeline.process_request`:
   - extracts message facts (`MessageFactExtractor.resolve_conflicts`) [LLM/Vision → canonical facts],
   - runs the forecast (`FinancialEngine.evaluate_request`) [deterministic financial timeline & cash-flow],
   - selects a plan (`PaymentPlanner.select_plan` using request payment options) [deterministic candidate plans],
   - generates the explanation (`DecisionExplanation.generate`) [deterministic],
   - validates with `OutputValidator.validate` [deterministic validator].
6. Counts and ordering are verified (`Pipeline.verify_counts!`), then rows are written to `output.csv`.

### Money handling

All amounts are `BigDecimal` (see `Money`/`MoneyDSL` and `format_amount_for_csv`). Amounts are stored in the user's `home_currency`; FX uses dated rows from `exchange_rates.csv` in the `from_currency -> to_currency` direction for the event settlement date.

## Submission Artifacts

- `output.csv` — final predictions, repo root (not `dataset/output.csv`, which is the blank template).
- `code.zip` — solution + README + `evaluation/` for submission: https://www.hackerrank.com/contests/hackerrank-orchestrate-september26/challenges/buy-or-wait/submission
- `evaluation/usage_report.md` — token/cost report for the final full-dataset run.
- `log.txt` — chat transcript (gitignored; append via AGENTS §5).

@AGENTS.md
