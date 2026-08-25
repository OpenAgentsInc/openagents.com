# Models and pricing

[The models page](/models) lists every model this deployment serves, what each
one charges per million tokens, and where those rates came from. Read it before
you open a thread: a thread pins one model for its whole life, and the grant
that pays for it meters against that model's rates.

The page renders the same catalog as `GET /api/v1/models`, so the CLI and the
web cannot disagree about what is served or what it costs.

## What each column tells you

- **Model** — the id you name when you open a thread, and the provider lane that
  serves it. The default is the model a thread pins when you name none.
- **Availability** — `available`, `degraded`, or `unavailable`. A lane whose
  credential is not configured is listed as `unavailable` rather than hidden, and
  selecting it is refused by name. No call is ever answered by a different model
  than the one you asked for.
- **Input**, **Cached input**, and **Output** — US dollars per million tokens.
  Where a lane declares no cached rate, cached reads are charged at the input
  rate.
- **Basis** — where the rates came from, and the id of the rate table a call is
  priced against.
- **Context** — the context window, and the maximum output tokens one call can
  produce.

## Reading the basis

A price on this page is only as good as its source, so every lane says what its
source was.

- `declared` — the operator entered the provider's published rates. This is the
  only basis anything may bill from.
- `provisional` — rates written to make the system run, or rates whose table this
  deployment can no longer resolve. A working figure, not a bill.
- `unpriced` — no rates at all. Calls on this lane record no cost.

An unpriced lane is not a free lane. It is the deployment saying it does not know
what a call cost, which is a different fact from the call having cost nothing. So
an unpriced lane shows the word `Unpriced` instead of `$0.00`, a thread that
touched one reports no total spend rather than a total that looks complete, and
the lanes that made the total unknowable are named beside it.

That distinction survives everywhere the number goes: the models page, the thread
page, `GET /api/v1/threads/{id}`, and your account balance, which publishes
whether it is complete.

## Ceilings

A grant carries call, token, and cost ceilings. A cost ceiling can only stop
spend it can measure, so a grant on an unpriced lane is bounded by its call and
token ceilings instead. The thread page shows both what a grant has spent and
what it may spend, and an unbounded ceiling reads as `∞` rather than as a blank.

## Reading the catalog from the CLI

The same list is available over the API:

```sh
openagents api models
```

Every entry carries `availability` and `pricing_basis`. An unpriced model
publishes no `pricing` block, so a client that checks for the key sees no price
rather than a zero.
