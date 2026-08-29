# Postmortem - <incident, one line>

- **Severity:** SEV-<0-5>
- **Duration:** <time from first impact to full recovery>
- **Trigger:** <the event that set it off, one line>
- **Root cause:** <the mechanism, one line>
- **Contributors:** <who worked the incident and this write-up>

## TL;DR

- **What happened:** <one or two sentences a reader without domain knowledge
  can follow>
- **Impact:** <who or what was affected, how badly, for how long>
- **Resolution:** <what fixed it, with the fix PR or commit>

## Status

Draft

One of Draft / Reviewed / Closed on the line above; it is what the index
shows. Start the postmortem as a Draft *during* the incident, not after it:
capture the timeline, decisions, and communications as they happen - they are
hard to reconstruct accurately later. Reviewed once the people involved have
read it, Closed once every action item is done or explicitly dropped.

A postmortem is blameless and shared broadly: it answers *what*, *how*, and
*when* - never *who*. Look for the process and conditions that allowed the
incident, never a culprit. Refer to individuals by role or team ("an
engineer", "the owning team"), never by name or email - `docs-check` rejects
email addresses in postmortems. Individual attribution (audit-log principals,
who to follow up with) belongs in the linked internal investigation, which is
also where the follow-up with the person is tracked. Blameless is still not
vague: name concrete mechanisms, and give remediation items an owning team.

## Severity

Justify the level in a sentence. When unsure between two levels during the
incident, take the higher one and settle it here.

| Level | Meaning |
| --- | --- |
| SEV-0 | Blackout, no workaround, coordinated effort required |
| SEV-1 | Critical, warrants public notification and executive liaison |
| SEV-2 | Critical system issue impacting many customers |
| SEV-3 | Stability or minor customer-impacting issue needing immediate attention |
| SEV-4 | Minor issue requiring action, customers unaffected |
| SEV-5 | Cosmetic |

## Impact

Quantify: which systems, users, or flows; degradation vs outage; duration per
surface; data loss if any. Say explicitly what was *not* affected when that
was in doubt during the incident. Raw error counts need context - low traffic
can make a total outage look small.

## Timeline

Chronological, one timezone, say which (UTC preferred). This is the big
picture: the lead-up to the incident (the detailed trace belongs in the
linked investigation), its discovery, and how it was handled. Cover when the
problem *started* (not just when it was noticed), detection, key decisions,
mitigations, dead ends that cost time, communications sent, and confirmed
recovery. Link the Slack threads, tickets, and dashboards beside the entries
they support. Fill this table live during the incident.

Every row carries a time (`hh:mm` UTC; prefix the date when it changes or is
ambiguous) - `docs-check` enforces this on report timeline tables. When an
event is reported without a time, stamp it with the current `date -u` at the
moment it is logged - the write-up runs live, so "now" is the honest
timestamp. Prefix with `~` when the time is approximate or inferred.

Times are often quoted in local zones: convert to UTC for the row, and feel
free to keep the local views in parentheses. Use
`.local/scripts/report-time` for both - e.g. `report-time --from Europe 10:14`
prints `2026-08-26 09:14 UTC (10:14 Europe)`; configure your team's zones in
`[reports].timezones` of `.local/project-kit.toml`. Never convert by head:
the machine, chat, and cloud consoles may each show a different timezone.

| Time (UTC) | Event |
| --- | --- |
| YYYY-MM-DD hh:mm | <first cause lands> |
| hh:mm | <detection - alert or human> |
| hh:mm | <mitigation, resolution, recovery confirmed> |

## Detection

How it was noticed - alert, user report, chance - and the gap between start
and detection. If existing monitoring should have caught it earlier, say what
signal was missing or mis-scaled.

## Communications

How the incident was communicated while it was being handled: the Slack
channels and threads used for mitigation coordination (link them), status
updates or notifications sent to affected teams or customers, and who was
informed when. Note gaps - a team that found out on its own belongs here.

## Root cause analysis

The mechanism, in enough detail to be checked: what made the failure
possible, what triggered it, and the evidence (reproduction, logs, data) that
confirmed it. Distinguish the trigger from the underlying causes, and
confirmed facts from remaining hypotheses.

### Contributing factors

Bullet the conditions that let the trigger become an incident: defaults
nobody set, missing alerts, silent changes, tooling whose behavior differs
from production, shared failure domains.

## Resolution

The actions that resolved it and their outcomes, including temporary
mitigations still in place. Link the fix PR or commit. If recovery is
inferred rather than observed (no traffic since the fix), say so.

## Lessons learned

What went well and what went poorly - process and tooling, not people.
Include what would have detected the problem sooner or shrunk the blast
radius.

## Remediation

One owner and a status per item; "be more careful" does not count. Keep the
list current as items land - the postmortem closes when every item is done or
explicitly dropped.

### Short term

Stop the bleeding and catch a recurrence: fixes, alerts, runbooks.

- [ ] <action> - <owner>

### Medium term

Harden the surrounding system: audits of the same defect elsewhere, tooling,
game days.

- [ ] <action> - <owner>

### Long term

Remove the failure class: architecture changes, isolation, ownership moves.
Record the trade-offs considered, not just the intent.

- [ ] <action> - <owner>

## Conclusion

A short paragraph: what broke, how it was resolved, and what changes as a
result.

## References

- Fix: <PR or commit>
- Related bug or investigation: <link or none>
- Code / config: <paths>
- Logs, dashboards, threads: <links or none>
