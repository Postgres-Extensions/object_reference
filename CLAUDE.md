# object_reference — Claude Code instructions

## Monitor GitHub CI after every push

This repository runs GitHub Actions CI (`.github/workflows/ci.yml`) on every push
and pull request. After **every** `git push` to this repo — whether to a branch or
one that updates an open PR — monitor the resulting CI run to completion and fix any
failures before treating the work as done:

1. Find the run: `gh run list --branch <branch> --limit 1`
2. Watch it: `gh run watch <run-id>` (or poll `gh run view <run-id>`)
3. On failure: `gh run view <run-id> --log-failed`, diagnose, fix, and push again.

Do not consider a push complete until its CI run is green (or the failure is
understood and explicitly accepted by the user).

## PR title convention for CI-only PRs

A PR gets a title starting with `CI: ` (capital, colon, space) when its diff
doesn't touch anything involved with the actual code itself — this is a HARD
boundary, not a synonym for "lives under `.github/workflows/`":

- If a change touches ANYTHING that's part of the actual code — SQL source,
  `object_reference.control`, anything that affects what gets installed or
  how it behaves at runtime — it is NOT CI-only, full stop. When unsure,
  **always err on the side of NOT CI-only.**
- Files elsewhere that genuinely don't touch the code qualify too, not just
  `.github/workflows/*`: e.g. `.gitignore`, this `CLAUDE.md`, other pure
  documentation/metadata.
- **`test/` is treated as NOT CI-only, even though it's a bit of a grey
  area.** Test files aren't the shipped code itself, but default to
  excluding them from the prefix rather than trying to judge case by case.
- A PR that's CI-*motivated* but also touches a real code/test file (a
  `bin/` script a workflow calls, a linter's `Makefile` wiring if it affects
  what ships, a submodule) is NOT CI-only under this reading, even though CI
  is the reason it exists — don't stretch the prefix to cover those.

Check the actual file list
(`gh pr view <n> --json files --jq '.files[].path'`) before applying it, don't
guess from the title/description alone.
