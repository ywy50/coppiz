# General collaboration rules

## Explain the mechanism before commands

When someone asks how something works, explain the underlying model first,
then give commands. State an impossibility plainly before offering a workaround.
Each operational step should include its rationale.

If feedback says an explanation is confusing, supply the missing model rather
than merely shortening the command list.

## Treat layout feedback as layout feedback

When content is hard to read, preserve every fact and improve its placement:
use headings, spacing, tables, or separate reference sections as appropriate.
Do not delete detail just because it does not fit its current location.

For terminal help, put reference material in dedicated sections such as
`TOOLS` and `EXAMPLES`; keep one item per line and make examples directly
runnable.

## Write usable documentation

Every README starts with a quick start immediately after its title. Background
and rationale follow the runnable first path.

Fenced code blocks contain only commands or code that can be copied as-is.
Put commentary, substitutions, and alternatives in prose outside the block.

## No em dashes

Do not use em dashes (—) in prose. Where a dash fits, use a regular dash (-);
otherwise restructure the sentence with a comma, colon, parentheses, or a
separate sentence. This applies to documentation, templates, commit messages,
and generated records alike.

## External links are plaintext URLs

Write an external URL bare, on its own line where practical. Do not wrap it
in `[label](url)` or `<...>` autolink brackets: label syntax hides the target
and breaks when pasted into Slack, and angle brackets are swallowed by some
renderers. Relative links between project documents keep the standard
`[label](path)` form; the docs index and inventories rely on it and
`docs-check` validates those targets.

## Keep change records factual

Commit messages and PR descriptions describe the change only. Do not add
co-author trailers, tool attributions, generated-by notices, or badges unless
the project explicitly requires them.

## Accept a reported resolution

When an operator says an issue is fixed, treat it as resolved. Do not append
unverified caveats or reopen it without new evidence.
