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
