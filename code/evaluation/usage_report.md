# Usage Report — Final Full-Dataset Run

## Run Summary

| Metric | Value |
|---|---:|
| Requests processed | 250 |
| Output rows written | 250 |
| Requests requiring LLM | 200 |
| Deterministic-only requests | 50 |
| Image extractions | 11 |
| Message extractions | 198 |
| Validation failures | 0 |

The final run completed successfully with `ruby code/main.rb`. All 250 output rows passed `OutputValidator` before `output.csv` was written.

### Validation Summary

Stage 9 verification tests confirm:
- **Sample request outputs pass validation** (0 errors)
- **Previously failing requests now valid** (0 remaining failures)
- **Core payment decision invariants hold** (0 violations)
- **Spending changes preserve baseline-safe values** (no unsafe full_payment selections)
- **Full pipeline produces valid output.csv** (250 rows, correct schema)
- **Full regression across Stages 2-8** (0 regressions)

## Model Providers and Names

| Role | Provider | Model |
|---|---|---|
| Vision extraction | Gemini | `gemini-2.0-flash` |
| Message fact extraction | Gemini | `gemini-2.0-flash` |

The pipeline uses mock providers by default. The final run used the Gemini providers configured through environment variables:

```bash
VISION_PROVIDER=gemini
MESSAGE_PROVIDER=gemini
VISION_MODEL=gemini-2.0-flash
MESSAGE_MODEL=gemini-2.0-flash
```

No credentials are included in this report or the submitted code package.

## Token Usage

The pipeline does not instrument provider-level token counters. Values below are conservative estimates based on the final run's actual extraction counts and typical prompt/response sizes for this workload.

| Call type | Calls | Est. input tokens/call | Est. output tokens/call | Est. input tokens | Est. output tokens |
|---|---:|---:|---:|---:|---:|
| Vision (image amount extraction) | 11 | ~500 | ~80 | ~5,500 | ~880 |
| Message (fact extraction) | 198 | ~600 | ~150 | ~118,800 | ~29,700 |
| **Total** | **209** | — | — | **~124,300** | **~30,580** |

### Totals and Averages

| Metric | Estimate |
|---|---:|
| Total input tokens | ~124,300 |
| Total output tokens | ~30,580 |
| Total tokens | ~154,880 |
| Average input tokens per request | ~497 |
| Average output tokens per request | ~122 |
| Average total tokens per request | ~619 |

## Estimated Cost

Using Gemini 2.0 Flash pricing (uncached input, conservative estimate):

| Component | Tokens | Rate | Estimated cost |
|---|---:|---:|---:|
| Input | ~124,300 | $0.50 / 1M tokens | ~$0.062 |
| Output | ~30,580 | $2.50 / 1M tokens | ~$0.076 |
| **Total** | **~154,880** | — | **~$0.138** |

### Cost Per Request

- Estimated total cost: **~$0.138**
- Estimated cost per request: **~$0.00055** (about 0.055 cents)

These figures are estimates. Actual billed tokens and costs depend on provider-side tokenization, image token accounting, and any prompt caching applied by the API. The deterministic financial decision engine performs no external calls and incurs no additional token usage.
