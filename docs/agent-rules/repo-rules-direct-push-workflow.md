# Repository rule: direct-push workflow

This is a permissive rule. It authorizes direct commits and pushes only for the
repositories listed below; it does not require them. Every other repository
follows its own applicable workflow, including any restrictive branch, PR, and
merge rule.

## Repositories with a direct-push allowance

- <owner/repo - no repositories listed yet; add them here before citing this rule>

For every listed repository, commit only the completed path-scoped change and
push it directly to `origin/main`. Do not open a pull request. Preserve
unrelated uncommitted work through explicit-path staging. A repository-specific
overlay may refine the allowance, such as limiting it to a named branch.
