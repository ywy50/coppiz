# Agent-rule library

`general.md` is installed as the project kit's baseline collaboration policy.

The repository workflow rules below ship with an empty scope: each project
fills the bullet list in its own installed copy, and the installer never
overwrites an existing copy, so a filled-in scope survives reinstalls. A rule
with no repositories listed governs nothing.

`repo-rules-merge-workflow.md` is a restrictive worktree branch → PR → merge
rule: work happens in a git worktree on its own branch, never on the main
checkout's default branch, and ends with a merged pull request. Its scope is
the explicit bullet list in that file; repositories outside the list are not
governed by it.

`repo-rules-pr-workflow.md` is a restrictive worktree branch → PR rule
without automatic merging: same lifecycle, but it ends with a pushed branch
and an open pull request - merging is left to the operator.

`repo-rules-direct-push-workflow.md` is a permissive direct-push allowance.
Only its explicit bullet list is authorized to commit and push directly, and
the allowance does not require a direct push.

`repo-rules-ci-failure-allowance.md` is a permissive CI-failure allowance.
Only its explicit bullet list is authorized to proceed despite failed CI; the
allowance does not require a failure to be ignored.

`repository-rule-template.md` records how to create or extend repository
rules: one workflow per module, an explicit bulleted scope, and narrow
repository-specific overlays for exceptions. Repository-specific overlays are
project property: create them in the project's own `docs/agent-rules/`, named
after the repository they refine; the kit ships none.
