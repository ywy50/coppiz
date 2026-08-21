# Runbooks

Current recovery procedures for recurring failures. A runbook is the concise
*what to do now*; the history of how the failure was found and fixed stays in
its [report](../reports/). Name runbooks by the failure they recover from,
keep every step with its rationale, and put only runnable commands inside
fenced blocks.

## Inventory

None yet. The first ones the design already predicts are listed in
[open-questions.md](../open-questions.md): rolling upgrade (OQ 26), backup and
restore without forking the chain (OQ 39), and offline reconfigure when
`leadership.reconfigurable = false` (OQ 5).
