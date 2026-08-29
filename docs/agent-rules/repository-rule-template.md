# Repository rule template

Use this template when defining a repository workflow rule. Keep one workflow
regime per module so a restrictive requirement cannot be mistaken for a
permissive allowance.

## Scope

State the rule's scope immediately after the title, using a bullet list of
repository identifiers. A wildcard is valid, but it must be a bullet item -
never described only in flowing text.

## Restrictive workflow module

Use a restrictive module when covered repositories must follow a specific
lifecycle, such as branch → PR → merge. Say that the rule applies only to the
listed repositories. State the prohibited shortcut, the required lifecycle,
and the limited reasons it may stop before completion.

## Permissive workflow module

Use a permissive module to authorize, not require, a workflow such as direct
commit and push or proceeding despite CI failures. List every repository with
that allowance, then state the allowed behavior and any conditions below the
list.

## Repository-specific overlay

Use a narrow overlay for facts that belong to one repository, such as a
main-branch direct-push allowance. Name the repository in the title and say
that the overlay applies only there. It may refine a permissive allowance, but
must not make an unrelated restrictive workflow appear to apply.

## Agent entry point

The repository's `AGENTS.md` remains the agent entry point. It explicitly
names the general rules plus every workflow module and overlay that applies to
that checkout. Do not infer applicability just because a module exists in the
rule library.
