# Repository rule: worktree branch, PR, no automatic merge

This is a restrictive rule. It applies only to these repositories, including
their local checkouts:

- <owner/repo - no repositories listed yet; add them here before citing this rule>

Never commit or push directly to a covered repository's default branch, and
never merge a pull request. Before starting the work, first create a git
worktree with a new branch - in a workspace via the project-kit tooling
(`project-worktree`, `project-kit.py worktree`, or `agent-worktree-task.sh`),
which places it under `.local/worktrees/`; the shared checkout stays on its
default branch.

Then, inside the worktree and before any work happens, make sure the branch
is based on the latest remote state: fetch `origin` and set the branch onto
the remote default branch's fetched tip (such as `origin/main`), never
leaving it on the local checkout's possibly stale copy. Do all the work
inside the worktree.

When the unit of work is complete, autonomously commit the worktree's
changes, push the branch, and open a pull request. Stop there: merging is the
operator's decision and happens only when the operator explicitly asks for
it. Report the PR link and its check status. Remove the worktree only after
its branch is merged.

If reusable work is needed in another covered repository, follow the same
independent worktree branch → PR lifecycle there. Keep the originating
project usable without relying on an unmerged upstream change.
