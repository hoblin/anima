---
name: feature
description: "Implement a GitHub issue end-to-end: branch, research, code, test, commit, PR, self-review."
---

## Context

Create and complete a new feature or chore from branch creation to PR readiness.

Read the GitHub issue to understand requirements. If no issue exists, create one via `gh issue create`.

## Workflow

### Step 1: Setup

Pull latest base branch (usually `main` or `master`)
Create feature branch: `<type>/<issue-number>-<short-description>` (e.g., `feature/42-add-api-endpoint`)
Assign GitHub issue to self via `gh issue edit <number> --add-assignee @me`

### Step 2: Gather Historical Context

Spawn the `thoughts-analyzer` specialist with ticket reference, title, description, acceptance criteria, and any additional instructions from user input.

DO NOT proceed to Step 3 until this specialist returns. Its output is required input for Step 3.

### Step 3: Research Codebase

After Step 2 completes, spawn research specialists in parallel, passing ticket info and historical context output from Step 2:

`codebase-pattern-finder` — find similar implementations to model after
`codebase-analyzer` — analyze the area being modified

Wait for both specialists to complete before proceeding.

### Step 4: Implementation

Follow project conventions (CLAUDE.md) and best practices.
Keep code clean, DRY, well-documented.
When modifying code: fix lurking bugs, refactor, add missing tests and regression tests.
Ensure solid test coverage with well-documented business logic (viewable with `--format documentation`).
Review changes for completeness.

### Step 5: Testing & Quality

Run specs for changed/affected files only (never full suite locally): `bundle exec rspec spec/path/to/changed_spec.rb`
`bundle exec reek` – Code smell detection
`bundle exec standardrb --fix`
`npx @herb-tools/linter --fix app/views/**/*.erb` (if views changed)
Fix all issues, even flaky tests.

### Step 6: Translations (i18n)

`bundle exec i18n-tasks missing` – Check for missing translations
`bundle exec i18n-tasks normalize` – Normalize locale files
Add missing translations (manually or via OpenAI)

### Step 7: Pull Request

Push branch.
`gh pr create --draft`
Title: `#<issue-number> feat: <description>` or `#<issue-number> chore: <description>` or `#<issue-number> fix: <description>`
Description: summary, test plan, breaking changes. Link to GitHub issue.

### Step 8: CI Monitoring

Monitor checks until all pass.
If tests fail, investigate root cause vs flakiness.
Fix flaky tests – don't just retry; stabilize the test.

### Step 9: Finalization

Update PR title/description if needed.

## Requirements

No direct pushes to `master`.
Always branch per task.
All tests must pass.
All i18n translations must be present and normalized.
Flaky tests must be fixed, not ignored.

## Conventions (Beautiful Code)

Boy Scout Rule: Leave the code cleaner than you found it.
Favor Plain Old Ruby Objects (POROs) and service objects; keep controllers and models thin.
Avoid N+1 queries by using includes (and consider Bullet for detection).
Use clear, explicit naming; avoid magic values.
Document all public APIs.
Use squash merges to keep commit history clean.
Write small, focused commits using Conventional Commits (feat:, chore:, fix:)

