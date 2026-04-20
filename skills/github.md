---
name: github
description: "GitHub operations — issues, pull requests, releases, CI runs, comments. Activate when an issue or PR number comes up, or when the conversation turns to repo state."
---

# GitHub

`gh` is installed and authenticated.

## Sub-issues — REST only

Not in top-level `gh` commands. Use the issue's *global ID* (not its number):

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
ISSUE_ID=$(gh api repos/$REPO/issues/42 --jq '.id')

# add
gh api repos/$REPO/issues/36/sub_issues -X POST -F sub_issue_id=$ISSUE_ID

# list
gh api repos/$REPO/issues/36/sub_issues

# reorder (move one to sit after another)
gh api repos/$REPO/issues/36/sub_issues/priority -X PATCH \
  -F sub_issue_id=$ISSUE_ID -F after_id=$AFTER_ID
```

## Reading JSON

`gh` JSON output is token-expensive. Pipe through `toon` — a lossless LLM-optimized format that round-trips back to JSON:

```bash
gh pr view 459 --json title,body,reviewDecision | toon
gh api repos/$REPO/pulls/459/comments | toon
```

Skip `toon` when the output is going into further tooling that needs raw JSON (jq, scripts).
