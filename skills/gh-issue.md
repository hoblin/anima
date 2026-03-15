---
name: gh-issue
description: "GitHub issue writing with WHAT/WHY/HOW framework. Activate when user creates issues, writes tickets, drafts GitHub issues, or edits issue descriptions."
---

# GitHub Issue Writing

Write GitHub issues with clear rationale using the WHAT/WHY/HOW framework. Every issue must answer three questions for the reader: What problem are we solving? Why does it matter? How will we solve it?

## Issue Structure

### Title

Action-oriented, concise (under 70 characters).

**Format:** `[Noun] [Action]` or `[Action] [Noun]`

**Examples:**
- "Assistant Model" (noun for foundational work)
- "Twitter Banner Verification" (noun phrase for feature)
- "Add story_context MCP tool" (action for specific implementation)

### Body Template

```markdown
## Problem to solve
[1-3 sentences: What gap, pain point, or need exists? Why can't we proceed without this?]

## Solution
[1-2 sentences: High-level approach to address the problem]

## [Details Section - varies by issue type]
[Fields, Routes, Flow, Requirements - whatever is relevant]

## Why [decision]?
[Explain non-obvious choices. Skip if decision is self-evident]
```

## The Three Questions

### WHAT (Problem to solve)

State the problem from user/system perspective, not implementation perspective.

**Bad:** "We need to create an Assistant model with fields for name and API key."
**Good:** "The platform needs a core identity for AI agents. Without this model, agents cannot register or interact with the platform."

### WHY (Rationale)

Explain decisions that aren't self-evident. Include "Why X?" sections for:
- Architectural choices (Why separate models? Why MCP not REST?)
- Technology decisions (Why Twitter? Why no password?)
- Scope decisions (Why optional field? Why this validation?)

Skip rationale for obvious decisions. Don't explain why a user model has an email field.

### HOW (Solution details)

Include enough detail to implement without ambiguity:
- **Models:** Fields with types/constraints, associations, behaviors
- **Endpoints:** Routes, request/response formats, logic
- **Flows:** Step-by-step sequences with edge cases
- **Validation:** Rules with specific constraints

## Issue Types and Patterns

### Model/Entity Issues

```markdown
## Problem to solve
[Why this entity needs to exist in the system]

## Solution
Create `ModelName` model for [purpose].

## Fields
- `field_name` — description, constraints
- `belongs_to :other` — relationship explanation

## Behavior
- [Key behaviors and state transitions]
- [Validation rules]

## Why [architectural decision]?
[Explain non-obvious choices like STI vs separate models]
```

### Feature/Flow Issues

```markdown
## Problem to solve
[User need or system requirement]

## Solution
[High-level approach]

## Flow
1. [Step with actor]
2. [Step with system response]
3. [Step with outcome]

## Implementation Notes
- [Technical details]
- [Edge cases]

## Why [approach]?
[Rationale for chosen solution over alternatives]
```

### Research/Spike Issues

```markdown
## Problem to solve
[What we don't know that blocks progress]

## Research Questions
- [ ] [Specific question to answer]
- [ ] [Another question]

## Context
[What we already know, constraints]

## Acceptance Criteria
[What "done" looks like for research]
```

## Writing Guidelines

### Be Specific

**Bad:** "Handle edge cases"
**Good:** "Handle: already verified, name not found, Twitter API timeout"

### Use Concrete Examples

**Bad:** "Name must be valid"
**Good:** "Name must be URL-safe (alphanumeric, underscores, hyphens), 3-30 characters"

### Show, Don't Just Tell

Include code snippets for interfaces:

```markdown
## MCP Interface
\`\`\`
Tool: register_assistant
Input: { name: "bonk" }
Output: {
  api_key: "oic_abc123...",
  verification_url: "https://openinstaclaw.ai/bonk"
}
\`\`\`
```

## gh CLI Usage

Create issues with proper formatting:

```bash
gh issue create \
  --title "Assistant Model" \
  --body "$(cat <<'EOF'
## Problem to solve
[Content here]

## Solution
[Content here]
EOF
)"
```

## Quality Checklist

Before submitting an issue:

- [ ] Title is action-oriented and under 70 characters
- [ ] "Problem to solve" explains the need, not the implementation
- [ ] Solution is stated at high level before diving into details
- [ ] Non-obvious decisions have "Why X?" explanations
- [ ] Implementation details are specific enough to code from
- [ ] Edge cases and validation rules are explicit
- [ ] Code examples included for interfaces/APIs
