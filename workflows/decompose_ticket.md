---
name: decompose_ticket
description: "Decompose a feature ticket into vertical slices — testable, deliverable units ordered by dependency."
---

# Decompose Ticket

Break a feature ticket into vertical slices. Each slice is a testable, deliverable unit that can be implemented, reviewed, and merged independently.

## The Principle

**Never decompose by layer. Always decompose by function.**

Horizontal (wrong):
- Task 1: Routes
- Task 2: Model
- Task 3: Controller
- Task 4: Views

Each piece is untestable in isolation. Nothing is deliverable until everything is done.

Vertical (correct):
- Slice 1: Model + index action + seeds → immediately visible
- Slice 2: Show action → testable independently
- Slice 3: Edit/update actions → independently deliverable
- Slice 4: Delete action → independently deliverable

Each slice = working functionality that can be tested and reviewed on its own.

## Process

### Step 1: Understand the Ticket

Read the GitHub issue thoroughly. Identify:
- What is the desired end state?
- What are the acceptance criteria?
- What components are involved (models, controllers, views, services, jobs)?

Spawn the `thoughts-analyzer` specialist to find historical context about the feature area.

### Step 2: Identify the Minimum Viable Slice

The first slice must be the smallest unit that produces something visible/testable:

**For Rails features:**
- Model + migration + seeds + one controller action + route + minimal view
- This is the "can I see something working?" threshold

**For API features:**
- Model + migration + one endpoint + request spec
- This is the "can I call it and get a response?" threshold

**For library/gem features:**
- Core class + public method + unit spec
- This is the "can I use it from a console?" threshold

### Step 3: Slice by Function

After the minimum slice, decompose remaining work by function:

1. **Read-only first**: index, show, list, get — safe, easy to verify
2. **Mutations second**: create, update, delete — each independently
3. **Edge cases last**: error handling, validations, authorization — after happy path works

Each slice must:
- Build on previous slices (no orphaned dependencies)
- Be independently testable
- Have clear acceptance criteria
- Be small enough for a single PR

### Step 4: Create Sub-Issues

For each slice, create a GitHub sub-issue:
- Title: `Slice N: <what it delivers>`
- Body: What's included, what's NOT included, acceptance criteria, dependencies
- Link as sub-issue to the parent ticket

```bash
# Create sub-issue
gh issue create --title "Slice 1: Model + index" --body "..."

# Link as sub-issue to parent
ISSUE_ID=$(gh api repos/{owner}/{repo}/issues/{new_number} --jq '.id')
gh api repos/{owner}/{repo}/issues/{parent_number}/sub_issues -X POST -F sub_issue_id=$ISSUE_ID
```

### Step 5: Order and Verify

Review the full sequence:
- Does each slice build on the previous?
- Is the first slice the smallest possible visible unit?
- Can each slice be tested without the ones after it?
- Are there any horizontal slices disguised as vertical? (e.g., "all migrations" is horizontal)

Present the decomposition for review before creating issues.

## Anti-Patterns

- **"Set up the database first"** — horizontal. Include only the migration needed for slice 1.
- **"Add all routes"** — horizontal. Add routes as each action is implemented.
- **"Write all tests at the end"** — horizontal. Tests live with their slice.
- **"Refactor before building"** — unless blocking, refactoring is its own slice.

## Guidelines

- Fewer, larger slices are better than many tiny ones — each slice has PR overhead
- The first slice should be demonstrable within hours, not days
- When in doubt about order: read before write, simple before complex, core before edge
- Each slice should leave the codebase in a working state (green tests)
