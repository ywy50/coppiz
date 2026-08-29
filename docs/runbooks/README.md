# Runbooks

Current recovery procedures for recurring failures. A runbook is the concise
*what to do now*; the history of how the failure was found and fixed stays in
its [report](../reports/). Name runbooks by the failure they recover from,
keep every step with its rationale, and put only runnable commands inside
fenced blocks.

## Inventory

None yet. The first ones the design already predicts are listed with the
records that will settle them: rolling upgrade ([RFC 0023](../rfcs/0023-rolling-upgrade.md)),
backup and restore without forking the chain ([RFC 0024](../rfcs/0024-backup-restore.md)),
and offline reconfigure when `leadership.reconfigurable = false`
([RFC 0014](../rfcs/0014-offline-reconfigure.md)).
