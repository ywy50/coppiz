# Repository rule: worktree branch, PR, merge workflow

This is a restrictive rule. It applies only to these repositories, including
their local reference checkouts:

- <owner/repo - no repositories listed yet; add them here before citing this rule>

Never commit or push directly to a covered repository's default branch.
Before starting the work, first create a git worktree with a new branch; the
main checkout stays on its default branch.

Then, inside the worktree and before any work happens, make sure the branch
is based on the latest remote state: fetch `origin` and set the branch onto
the remote default branch's fetched tip (such as `origin/main`), never
leaving it on the local checkout's possibly stale copy. Do all the work
inside the worktree.

When the unit of work is complete, autonomously commit the worktree's
changes, push the branch, open a pull request, and merge it; remove the
worktree once its branch is merged. Leave a PR unmerged only when review is
required, checks fail, conflicts block the merge, or the operator explicitly
says so; report that reason.

If reusable work is needed in another covered repository, follow the same
independent worktree branch → PR → merge lifecycle there. Keep the
originating project usable without relying on an unmerged upstream change.
