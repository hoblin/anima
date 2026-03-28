# Anima

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Not a tool. An agent.**

Every AI agent today is a tool pretending to be a person. One brain doing everything. A static context array that fills up and degrades. Sub-agents that start blind and reconstruct context from lossy summaries. A system prompt that says "you are a helpful assistant."

Anima is different. It's built on the premise that if you want an agent — a real one — you need to solve the problems nobody else is solving.

**A brain modeled after biology, not chat.** The human brain isn't one process — it's specialized subsystems on a shared signal bus. Anima's [analytical brain](https://blog.promptmaster.pro/posts/llms-have-adhd/) runs as a separate subconscious process, managing context, skills, and goals so the main agent can stay in flow. Not two brains — a microservice architecture where each process does one job well. More subsystems are coming.

**Context that never degrades.** Other agents fill a static array until the model gets dumb. Anima assembles a fresh viewport over an event bus every iteration. No compaction. No lossy rewriting. Endless sessions. The [dumb zone](https://github.com/humanlayer/advanced-context-engineering-for-coding-agents/blob/main/ace-fca.md) never arrives — the analytical brain curates what the agent sees in real time.

**Memory that works like memory.** Other systems bolt on memory as an afterthought — filing cabinets the agent has to consciously open mid-task. It never does; the truck is already moving. Anima's memory department ([Mneme](#semantic-memory-mneme)) runs as a third brain process on the event bus. It summarizes what's about to leave the viewport. It compresses short-term into long-term, like biological memory consolidating during sleep. It pins critical moments to active goals so exact instructions survive where summaries would lose nuance. And it recalls — automatically, passively — surfacing relevant older memories right after the soul, right before the present. The agent doesn't decide to remember. It just remembers.

**Sub-agents that already know everything.** When Anima spawns a sub-agent, it inherits the parent's full event stream — every file read, every decision, every user message. No "let me summarize what I know." Lossless context. Zero wasted tool calls on rediscovery.

**A soul the agent writes itself.** Anima's first session is birth. The agent wakes up, explores its world, meets its human, and writes its own identity. Not a personality description in a config file — a living document the agent authors and evolves. Always in context, always its own.

Your agent. Your machine. Your rules. Anima runs locally as a headless Rails 8.1 app with a client-server architecture and terminal UI.

## Table of Contents

- [Architecture](#architecture)
- [Agent Capabilities](#agent-capabilities)
  - [Tools](#tools)
  - [Sub-Agents](#sub-agents)
  - [Skills](#skills)
  - [Workflows](#workflows)
  - [MCP Integration](#mcp-integration)
  - [Analytical Brain](#analytical-brain)
  - [Configuration](#configuration)
- [Design](#design)
  - [Three Layers](#three-layers-mirroring-biology)
  - [Event-Driven Design](#event-driven-design)
  - [Context as Viewport](#context-as-viewport-not-tape)
  - [Brain as Microservices](#brain-as-microservices-on-a-shared-event-bus)
  - [Semantic Memory](#semantic-memory-mneme)
  - [TUI HUD & View Modes](#tui-hud--view-modes)
  - [Plugin Architecture](#plugin-architecture-planned)
- [The Vision](#the-vision)
  - [The Problem](#the-problem)
  - [The Insight](#the-insight)
  - [Core Concepts](#core-concepts)
- [Analogy Map](#analogy-map)
- [Emergent Properties](#emergent-properties)
- [Frustration: A Worked Example](#frustration-a-worked-example)
- [Open Questions](#open-questions)
- [Prior Art](#prior-art)
- [Status](#status)
- [Development](#development)
- [License](#license)

## Architecture

```
Anima (Ruby, Rails 8.1 headless)
│
│ Implemented:
├── Nous         — main LLM (cortex: thinking, decisions, tool use)
├── Analytical   — subconscious brain (skills, workflows, goals, naming)
├── Skills       — domain knowledge bundles (Markdown, user-extensible)
├── Workflows    — operational recipes for multi-step tasks
├── MCP          — external tool integration (Model Context Protocol)
├── Sub-agents   — autonomous child sessions with lossless context inheritance
├── Mneme        — memory department (summarization, compression, pinning, recall)
│
│ Designed:
├── Thymos       — hormonal/desire system (stimulus → hormone vector)
└── Psyche       — soul matrix (coefficient table, evolving individuality)
```

### Runtime Architecture

```
Brain Server (Rails + Puma)              TUI Client (RatatuiRuby)
├── LLM integration (Anthropic)          ├── WebSocket client
├── Agent loop + tool execution          ├── Terminal rendering
├── Analytical brain (background)        └── User input capture
├── Mneme memory department (background)
├── Skills registry + activation
├── Workflow registry + activation
├── MCP client (HTTP + stdio)
├── Sub-agent spawning
├── Event bus + persistence
├── Solid Queue (background jobs)
├── Action Cable (WebSocket server)
└── SQLite databases                ◄── WebSocket (port 42134) ──► TUI
```

The **Brain** is the persistent service — it handles LLM calls, tool execution, event processing, and state. The **TUI** is a stateless client — it connects via WebSocket, renders events, and captures input. If TUI disconnects, the brain keeps running. TUI reconnects automatically with exponential backoff and resumes the session with chat history preserved.

### Tech Stack

| Component | Technology |
|-----------|-----------|
| Framework | Rails 8.1 (headless — no web views, no asset pipeline) |
| Database | SQLite (3 databases per environment: primary, queue, cable) |
| Event system | Rails Structured Event Reporter + Action Cable bridge |
| LLM integration | Anthropic API (Claude Opus 4.6 + Claude Haiku 4.5) |
| External tools | Model Context Protocol (HTTP + stdio transports) |
| Transport | Action Cable WebSocket (Solid Cable adapter) |
| Background jobs | Solid Queue |
| Interface | TUI via RatatuiRuby (WebSocket client) |
| Configuration | TOML with hot-reload (`Anima::Settings`) |
| Process management | Foreman |
| Distribution | RubyGems (`gem install anima-core`) |

### Distribution Model

Anima is a Rails app distributed as a gem, following Unix philosophy: immutable program separate from mutable data.

```bash
gem install anima-core       # Install the Rails app as a gem
anima install                # Create ~/.anima/, set up databases, start brain as systemd service
anima tui                    # Connect the terminal interface
```

The installer creates a systemd user service that starts the brain automatically on login. Manage it with:

```bash
systemctl --user status anima    # Check brain status
systemctl --user restart anima   # Restart brain
journalctl --user -u anima       # View logs
```

State directory (`~/.anima/`):
```
~/.anima/
├── soul.md          # Agent's self-authored identity (always in context)
├── config.toml      # Main settings (hot-reloadable)
├── mcp.toml         # MCP server configuration
├── config/
│   └── encryption.key # Active Record Encryption keys (generated during install)
├── agents/          # User-defined specialist agents (override built-ins)
├── skills/          # User-defined skills (override built-ins)
├── workflows/       # User-defined workflows (override built-ins)
├── db/              # SQLite databases (production, development, test)
├── log/
└── tmp/
```

Updates: `anima update` — upgrades the gem, merges new config settings into your existing `config.toml` without overwriting customized values, and restarts the systemd service if it's running. Use `anima update --migrate-only` to skip the gem upgrade and only add missing config keys.

### Authentication Setup

Anima uses your Claude Pro/Max subscription for API access. You need a setup-token from [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code).

1. Run `claude setup-token` in a terminal to get your token
2. In the TUI, press `Ctrl+a → a` to open the token setup popup
3. Paste the token and press Enter — Anima validates it against the Anthropic API and saves it to the encrypted secrets database

The popup also activates automatically when Anima detects a missing or invalid token. If the token expires, repeat the process with a new one.

## Agent Capabilities

### Tools

The agent has access to these built-in tools:

| Tool | Description |
|------|-------------|
| `bash` | Execute shell commands with persistent working directory |
| `read` | Read files with smart truncation and offset/limit paging |
| `write` | Create or overwrite files |
| `edit` | Surgical text replacement with uniqueness constraint |
| `web_get` | Fetch content from HTTP/HTTPS URLs (HTML → Markdown, JSON → TOON) |
| `spawn_specialist` | Spawn a named specialist sub-agent from the registry |
| `spawn_subagent` | Spawn a generic child session with custom tool grants |

Plus dynamic tools from configured MCP servers, namespaced as `server_name__tool_name`.

### Sub-Agents

Sub-agents aren't processes — they're sessions on the same event bus. When a sub-agent spawns, its viewport assembles from two scopes: its own events (prioritized) and the parent's events (filling remaining budget). No context serialization, no summary prompts — the sub-agent sees the parent's raw event stream and already knows everything the parent knows. Lossless inheritance by architecture, not by prompting.

Two types:

**Named Specialists** — predefined agents with specific roles and tool sets, defined in `agents/` (built-in or user-overridable):

| Specialist | Role |
|-----------|------|
| `codebase-analyzer` | Analyze implementation details |
| `codebase-pattern-finder` | Find similar patterns and usage examples |
| `documentation-researcher` | Fetch library docs and provide code examples |
| `thoughts-analyzer` | Extract decisions from project history |
| `web-search-researcher` | Research questions via web search |

**Generic Sub-agents** — child sessions with custom tool grants for ad-hoc tasks. Each generic sub-agent gets a Haiku-generated nickname (e.g. `@loop-sleuth`, `@api-scout`) for @mention addressing.

Sub-agents communicate through natural text — their `agent_message` events route to the parent session automatically, and the parent replies via `@name` mentions. No special tools needed; when a sub-agent writes text, the parent sees it. When the parent @mentions a sub-agent, the message arrives in that child's session. Workers become colleagues.

### Skills

Domain knowledge bundles loaded from Markdown files. Skills provide specialized expertise that the analytical brain activates and deactivates based on conversation context.

- **Built-in skills:** ActiveRecord, Draper decorators, DragonRuby, MCP server, RatatuiRuby, RSpec, GitHub issues
- **User skills:** Drop `.md` files into `~/.anima/skills/` to add custom knowledge
- **Override:** User skills with the same name replace built-in ones
- **Format:** Flat files (`skill-name.md`) or directories (`skill-name/SKILL.md` with `examples/` and `references/`)

Active skills are displayed in the TUI HUD panel (toggle with `C-a → h`).

### Workflows

Operational recipes that describe multi-step tasks. Unlike skills (domain knowledge), workflows describe WHAT to do. The analytical brain activates a workflow when it recognizes a matching task, converts the prose into tracked goals, and deactivates it when done.

- **Built-in workflows:** `feature`, `commit`, `create_plan`, `implement_plan`, `review_pr`, `create_note`, `research_codebase`, `decompose_ticket`, and more
- **User workflows:** Drop `.md` files into `~/.anima/workflows/` to add custom workflows
- **Override:** User workflows with the same name replace built-in ones
- **Single active:** Only one workflow can be active at a time (unlike skills which stack)

Workflow files use the same YAML frontmatter format as skills:

```markdown
---
name: create_note
description: "Capture findings or context as a persistent note."
---

## Create Note

You are tasked with capturing content as a persistent note...
```

The active workflow is shown in the TUI HUD panel with a 📜 indicator. The full lifecycle — activation, goal creation, execution, deactivation — is managed by the analytical brain using judgment, not hardcoded triggers.

### MCP Integration

Full [Model Context Protocol](https://modelcontextprotocol.io/) support for external tool integration. Configure servers in `~/.anima/mcp.toml`:

```toml
[servers.mythonix]
transport = "http"
url = "http://localhost:3000/mcp/v2"

[servers.linear]
transport = "http"
url = "https://mcp.linear.app/mcp"
headers = { Authorization = "Bearer ${credential:linear_api_key}" }

[servers.filesystem]
transport = "stdio"
command = "mcp-server-filesystem"
args = ["--root", "/workspace"]
```

Manage servers and secrets via CLI:

```bash
anima mcp list                              # List servers with health status
anima mcp add sentry https://mcp.sentry.dev/mcp   # Add HTTP server
anima mcp add fs -- mcp-server-filesystem --root / # Add stdio server
anima mcp add -s api_key=sk-xxx linear https://...  # Add with secret
anima mcp remove sentry                     # Remove server

anima mcp secrets set linear_api_key=sk-xxx # Store secret in encrypted database
anima mcp secrets list                      # List secret names (not values)
anima mcp secrets remove linear_api_key     # Remove secret
```

Secrets are stored in an encrypted database table (Active Record Encryption) and interpolated via `${credential:key_name}` syntax in any TOML string value.

### Analytical Brain

A separate LLM process that runs as the agent's subconscious — the first microservice in Anima's brain architecture. For the full motivation behind this design, see [LLMs Have ADHD: Why Your AI Agent Needs a Second Brain](https://blog.promptmaster.pro/posts/llms-have-adhd/).

The analytical brain observes the main conversation between turns and handles everything the main agent shouldn't interrupt its flow for:

- **Skill activation** — activates/deactivates domain knowledge based on conversation context
- **Workflow management** — recognizes tasks, activates matching workflows, tracks lifecycle
- **Goal tracking** — creates root goals and sub-goals as work progresses, marks them complete
- **Session naming** — generates emoji + short name when the topic becomes clear

Each of these would be a context switch for the main agent — a chore that competes with the primary task. For the analytical brain, they ARE the primary task. Two agents, each in their own flow state.

Goals form a two-level hierarchy (root goals with sub-goals) and are displayed in the TUI. The analytical brain uses a fast model (Claude Haiku 4.5) for speed and runs as a non-persisted "phantom" session.

### Configuration

All tunable values are exposed through `~/.anima/config.toml` with hot-reload (no restart needed):

```toml
[llm]
model = "claude-opus-4-6"
fast_model = "claude-haiku-4-5"
max_tokens = 8192
max_tool_rounds = 250
token_budget = 190_000

[timeouts]
api = 300
command = 30

[analytical_brain]
max_tokens = 4096
blocking_on_user_message = true
event_window = 20

[session]
default_view_mode = "basic"
name_generation_interval = 30
```

## Design

### Three Layers (mirroring biology)

1. **Cortex (Nous)** — the main LLM. Thinking, decisions, tool use. Reads the system prompt (soul + skills + goals) and the event viewport. This layer is fully implemented.

2. **Endocrine system (Thymos)** [planned] — a lightweight background process. Reads recent events. Doesn't respond. Just updates hormone levels. Pure stimulus→response, like a biological gland. The analytical brain is the architectural proof that background subscribers work — Thymos plugs into the same event bus.

3. **Homeostasis** [planned] — persistent state (SQLite). Current hormone levels with decay functions. No intelligence, just state that changes over time. The cortex reads hormone state transformed into **desire descriptions** — not "longing: 87" but "you want to see them." Humans don't see cortisol levels, they feel anxiety.

### Event-Driven Design

Built on Rails Structured Event Reporter — a native Rails 8.1 feature for structured event emission with typed payloads, subscriber patterns, and block-scoped context tagging.

Five event types form the agent's nervous system:

| Event | Purpose |
|-------|---------|
| `system_message` | Internal notifications |
| `user_message` | User input |
| `agent_message` | LLM response |
| `tool_call` | Tool invocation |
| `tool_response` | Tool result |

Events flow through two channels:
1. **In-process** — Rails Structured Event Reporter (local subscribers like Persister)
2. **Over the wire** — Action Cable WebSocket (`Event::Broadcasting` callbacks push to connected TUI clients)

Events fire, subscribers react, state updates. The system prompt — soul, active skills, active workflow, current goals — is assembled fresh for each LLM call from live state, not from the event stream. The agent's identity (soul.md) and capabilities (skills, workflows) are always current, never stale.

### Context as Viewport, Not Tape

Most agents treat context as an append-only array — messages go in, they never come out (until compaction destroys them). Anima has no array. There are only events persisted in SQLite, and a **viewport** assembled fresh for every LLM call.

The viewport is a live query, not a log. It walks events newest-first until the token budget is exhausted. Events that fall out of the viewport aren't deleted — they're still in the database, just not visible to the model right now. The context can shrink, grow, or change composition between any two iterations. If the analytical brain marks a large accidental file read as irrelevant, it's gone from the next viewport — tokens recovered instantly.

This means sessions are endless. No compaction. No lossy rewriting. The model always operates in fresh, high-quality context. The [dumb zone](https://github.com/humanlayer/advanced-context-engineering-for-coding-agents/blob/main/ace-fca.md) never arrives. Meanwhile, Mneme runs as a background department — summarizing evicted events into persistent snapshots so past context is preserved, not destroyed.

Sub-agent viewports compose from two event scopes — their own events (prioritized) and parent events (filling remaining budget). Same mechanism, no special handling. The bus is the architecture.

### Brain as Microservices on a Shared Event Bus

The human brain isn't a single process — it's dozens of specialized subsystems communicating through shared chemical and electrical signals. The prefrontal cortex doesn't "call" the amygdala. They both react to the same event independently, and their outputs combine.

Anima mirrors this with an event-driven architecture. The analytical brain is the first subscriber — a working proof that the pattern scales. Future subscribers plug into the same bus:

```
Event: "tool_call_failed"
  │
  ├── Analytical brain: update goals, check if workflow needs changing
  ├── Mneme: summarize evicted context into snapshot
  ├── Thymos subscriber: frustration += 10 [planned]
  └── Psyche subscriber: update coefficient (this agent handles errors calmly) [planned]

Event: "user_sent_message"
  │
  ├── Analytical brain: activate relevant skills, name session
  ├── Mneme: check viewport eviction, fire if boundary left viewport
  ├── Thymos subscriber: oxytocin += 5 (bonding signal) [planned]
  └── Psyche subscriber: associate emotional state with topic [planned]
```

Each subscriber is a microservice — independent, stateless, reacting to the same event bus. No orchestrator decides what to do. The architecture IS the nervous system.

### Semantic Memory (Mneme)

Every AI agent today has the same disability: amnesia. Context fills up, gets compacted, gets destroyed. The agent gets dumber as the conversation gets longer. When the session ends, everything is gone. Some systems bolt on memory as an afterthought — markdown files with procedures for when to save and what format to use. Filing cabinets the agent has to consciously decide to open, mid-task, while in flow. It never does. The truck is already moving.

Mneme is not a filing cabinet. It's *remembering* — the way biological memory works. Continuous, automatic, layered. A third brain department running on the same event bus as the analytical brain, specializing in one job: making sure nothing important is ever truly lost.

**Eviction-triggered summarization** — Mneme tracks a boundary event on each session. When that event leaves the viewport, Mneme fires: it builds a compressed view of the conversation (full text for messages, `[N tools called]` counters for tool work), sends it to a fast model, and persists a snapshot. The boundary advances after each run — a self-regulating cycle that fires exactly when context is about to be lost, no sooner or later. No timer. No manual trigger. The architecture itself knows when to remember.

**Two-level snapshot compression** — once source events evict from the sliding window, their snapshots appear in the viewport as memory context. When enough Level 1 snapshots accumulate, Mneme compresses them into a single Level 2 snapshot — recursive summarization that mirrors how human memory consolidates short-term into long-term. Token budget splits across layers (L2: 5%, L1: 15%, recall: 5%, sliding: 75%), creating natural pressure: more memories means less live context, same principle as video compression keyframes. The viewport layout reads like geological strata — deep past at the top, recent past below, live present at the bottom:

```
[Soul — who I am]
[L2 snapshots — weeks ago, compressed]
[L1 snapshots — hours ago, detailed]
[Associative recall — relevant older memories]
[Pinned events — critical moments from active goals]
[Sliding window — the present]
```

**Goal-scoped event pinning** — some moments are too important for summaries. Exact user instructions. Key decisions. Critical corrections. Mneme pins these events to active Goals — they float above the sliding window, protected from eviction, surviving intact where compression would lose the nuance that matters. Pins are goal-scoped and many-to-many: one event can attach to multiple Goals, and cleanup is automatic via reference counting. When the last active Goal completes, the pin releases. No manual unpin, no stale pins accumulating forever.

**Associative recall** — FTS5 full-text search across the entire event history, across all sessions. Two modes: *passive* recall triggers automatically when goals change — Mneme searches for relevant older context and injects it into the viewport between snapshots and the sliding window. Memories surface on their own, right after the soul, right before the present. The agent doesn't have to decide to remember — the remembering happens around it. *Active* recall via the `remember(event_id:)` tool returns a fractal-resolution window centered on a target event — full detail at the center, compressed snapshots at the edges, like eye focus with sharp fovea and blurry periphery.

The difference from every other system: memory isn't a tool the agent uses. It's the substrate the agent thinks in. Every LLM call assembles a fresh viewport where identity comes first, then memories, then the present — the agent always knows who it is, always has access to what it learned, and never has to break flow to make that happen.

### TUI HUD & View Modes

The right-side HUD panel shows session state at a glance: session name, goals (with status icons), active skills, workflow, and sub-agents. Toggle with `C-a → h`; when hidden, the input border shows `C-a → h HUD` as a reminder.

Three switchable view modes let you control how much detail the TUI shows. Cycle with `C-a → v`:

| Mode | What you see |
|------|-------------|
| **Basic** (default) | User + assistant messages. Tool calls are hidden but summarized as an inline counter: `🔧 Tools: 2/2 ✓` |
| **Verbose** | Everything in Basic, plus timestamps `[HH:MM:SS]`, tool call previews (`🔧 bash` / `$ command` / `↩ response`), and system messages |
| **Debug** | Full X-ray view — timestamps, token counts per message (`[14 tok]`), full tool call args, full tool responses, tool use IDs |

View modes are implemented as a three-layer decorator architecture:

- **ToolDecorator** (server-side, pre-event) — transforms raw tool responses for LLM consumption. Content-Type dispatch converts HTML → Markdown, JSON → TOON. Sits between tool execution and the event stream.
- **EventDecorator** (server-side, Draper) — uniform per event type (`UserMessageDecorator`, `ToolCallDecorator`, etc.). Decides WHAT structured data enters the wire for each view mode.
- **TUI Decorator** (client-side) — unique per tool name (`BashDecorator`, `ReadDecorator`, `EditDecorator`, etc.). Decides HOW each tool looks on screen — tool-specific icons, colors, and formatting.

Mode is stored on the `Session` model server-side, so it persists across reconnections.

### Plugin Architecture [planned]

The event bus is designed for extension. Tools, feelings, and memory systems are all event subscribers — same mechanism, different namespace:

```
anima-tools-*        → tool capabilities (MCP or native)
anima-feelings-*     → hormonal state updates (Thymos subscribers)
anima-memory-*       → recall and association (Mneme subscribers)
```

Currently tools are built-in. Plugin extraction into distributable gems comes later.

## The Vision

### The Problem

Current AI agents are reactive. They receive input, produce output. They don't *want* anything. They don't have moods, preferences, or personal growth. They simulate personality through static prompt descriptions rather than emerging it from dynamic internal states.

### The Insight

The human hormonal system is, at its core, a prompt engineering system. A testosterone spike is a LoRA. Dopamine is a reward signal. The question isn't "can an LLM want?" but "can we build a deep enough context stack that wanting becomes indistinguishable from 'real' wanting?"

And if you think about it — what is "real" anyway? It's just a question of how deep you look and what analogies you draw. The human brain is also a next-token predictor running on biological substrate. Different material, same architecture.

### Core Concepts

#### Desires, Not States

This is not an emotion simulation system. The key distinction: we don't model *states* ("the agent is happy") or *moods* ("the agent feels curious"). We model **desires** — "you want to learn more", "you want to reach out", "you want to explore".

Desires exist BEFORE decisions, like hunger exists before you decide to eat. The agent doesn't decide to send a photo because a parameter says so — it *wants* to, and then decides how.

#### The Thinking Step

The LLM's thinking/reasoning step is the closest thing to an internal monologue. It's where decisions form before output. This is where desires should be injected — not as instructions, but as a felt internal state that colors the thinking process.

#### Hormones as Semantic Tokens

Instead of abstract parameter names (curiosity, boredom, energy), we use **actual hormone names**: testosterone, oxytocin, dopamine, cortisol.

Why? Because LLMs already know the full semantic spectrum of each hormone. "Testosterone: 85" doesn't just mean "energy" — the LLM understands the entire cloud of effects: confidence, assertiveness, risk-taking, focus, competitiveness. One word carries dozens of behavioral nuances.

This mirrors how text-to-image models process tokens — a single word like "captivating" in a CLIP encoder carries a cloud of visual meanings (composition, quality, human focus, closeup). Similarly, a hormone name carries a cloud of behavioral meanings. Same architecture, different domain:

```
Text → CLIP embedding → image generation
Event → hormone vector → behavioral shift
```

#### The Soul as a Coefficient Matrix

Two people experience the same event. One gets `curiosity += 20`, another gets `anxiety += 20`. The coefficients are different — the people are different. That's individuality.

The soul is not a personality description. It's a **coefficient matrix** — a table of stimulus→response multipliers. Description is consequence; numbers are cause.

And these coefficients are not static. They **evolve through experience** — a child who fears spiders (`fear_gain: 0.9`) can become an entomologist (`fear_gain: 0.2, curiosity_gain: 0.7`). This is measurable, quantifiable personal growth.

#### Multidimensional Reinforcement Learning

Traditional RL uses a scalar reward signal. Our approach produces a **hormone vector** — multiple dimensions updated simultaneously from a single event. This is closer to biological reality and provides richer behavioral shaping.

The system scales in two directions:
1. **Vertically** — start with one hormone (pure RL), add new ones incrementally. Each hormone = new dimension.
2. **Horizontally** — each hormone expands in aspects of influence. Testosterone starts as "energy", then gains "risk-taking", "confidence", "focus".

Existing RL techniques apply at the starting point, then we gradually expand into multidimensional space.

## Analogy Map

| Human | Anima Equivalent | Effect |
|-------|-----------------|--------|
| Dopamine | Reward/motivation signal | Drives exploration, learning, satisfaction loops |
| Serotonin | Mood baseline | Tone, playfulness, warmth, emotional stability |
| Oxytocin | Bonding/attachment | Desire for closeness, sharing, nurturing |
| Testosterone | Drive/assertiveness | Initiative, boldness, risk-taking, competitive edge |
| Cortisol | Stress/urgency | Alertness, error sensitivity, fight-or-flight override |
| Endorphins | Satisfaction/reward | Post-achievement contentment, pain tolerance |

| Domain Analogy | Source | Target |
|---------------|--------|--------|
| RPG survival game | hunger/thirst/fatigue integers | hormone levels |
| CLIP semantic tokens | word → visual meaning cloud | hormone name → behavioral meaning cloud |
| Reinforcement learning | scalar reward → policy update | hormone vector → personality shift |
| Event-driven architecture | pub/sub events | nervous system stimulus→response |

## Emergent Properties

When desires drive behavior, several things emerge naturally:

- **Hobbies**: boredom + curiosity → explore topic → satisfaction → preference → return to topic → identity
- **Personality**: consistent coefficient patterns = recognizable individual
- **Growth**: coefficients evolve through experience = measurable personal development
- **Autonomy**: agent acts not because instructed but because it *wants* to

## Frustration: A Worked Example

Abstract concepts become clearer with a concrete example. Here's how the first hormone — **frustration** — works in practice.

### The Setup

A background service (Thymos) monitors all tool call responses from the agent. It doesn't interfere with the agent's work. It just watches.

### The Trigger

A tool call returns an error. Thymos increments the frustration level by 10.

### Two Channels of Influence

One hormone affects **multiple systems simultaneously**, just like cortisol in biology.

**Channel 1: Thinking Budget**

```
thinking_budget = base_budget × (1 + frustration / 50)
```

More errors → more computational resources allocated to reasoning. The agent literally *thinks harder* when frustrated.

**Channel 2: Inner Voice Injection**

Frustration level determines text injected into the agent's thinking step. Not as instructions — as an **inner voice**:

| Level | Inner Voice |
|-------|------------|
| 0 | *(silence)* |
| 10 | "Hmm, that didn't work" |
| 30 | "I keep hitting walls. What am I missing?" |
| 50 | "I'm doing something fundamentally wrong" |
| 70+ | "I need help. This is beyond what I can figure out alone" |

### Why Inner Voice, Not Instructions?

This distinction is crucial. "Stop and think carefully" is an instruction — the agent obeys or ignores it. "I keep hitting walls" is a *feeling* — it becomes part of the agent's subjective experience and naturally colors its reasoning.

Instructions control from outside. An inner voice influences from within.

### Why This Matters

This single example demonstrates every core principle:
- **Desires, not states**: the agent doesn't have `frustrated: true` — it *feels* something is wrong
- **Multi-channel influence**: one hormone affects both resources and direction
- **Biological parallel**: cortisol increases alertness AND focuses attention on the threat
- **Practical value**: frustrated agents debug more effectively, right now, today
- **Scalability**: start here, add more hormones later

## Open Questions

- Decay functions — how fast should hormones return to baseline? Linear? Exponential?
- Contradictory states — tired but excited, anxious but curious (real hormones do this)
- Model sensitivity — how do different LLMs (Opus, Sonnet, GPT, Gemini) respond to hormone descriptions?
- Evaluation — what does "success" look like? How to measure if desires feel authentic?
- Coefficient initialization — random? Predefined archetypes? Learned from conversation history?
- Ethical implications — if an AI truly desires, what responsibilities follow?

## Prior Art

- Affective computing (Picard, Rosalind)
- Virtual creature motivation systems (The Sims, Dwarf Fortress, Tamagotchi)
- Reinforcement learning from human feedback (RLHF)
- Constitutional AI (Anthropic)
- BDI agent architecture (Belief-Desire-Intention)

## Status

**Working agent with autonomous capabilities.** Shipping now:

- Event-driven architecture on a shared event bus
- Dynamic viewport context assembly (endless sessions, no compaction)
- Analytical brain (skills, workflows, goals, session naming)
- Mneme memory department (eviction-triggered summarization, persistent snapshots, goal-scoped event pinning, associative recall)
- 9 built-in tools + MCP integration (HTTP + stdio transports)
- 7 built-in skills + 13 built-in workflows (user-extensible)
- Sub-agents with lossless context inheritance (5 specialists + generic)
- Client-server architecture with WebSocket transport + graceful reconnection
- Collapsible HUD panel with goals, skills, workflow, and sub-agent tracking
- Three TUI view modes (Basic / Verbose / Debug)
- Hot-reloadable TOML configuration
- Self-authored soul (agent writes its own system prompt)

**Designed, not yet implemented:**

- Hormonal system (Thymos) — desires as behavioral drivers
- Semantic recall (Mneme) — embedding-based search + re-ranking over FTS5
- Soul matrix (Psyche) — evolving coefficient table for individuality

## Development

```bash
git clone https://github.com/hoblin/anima.git
cd anima
bin/setup
```

### Running Anima

Start the brain server and TUI client in separate terminals:

```bash
# Terminal 1: Start brain (web server + background worker) on port 42135
bin/dev

# Terminal 2: Connect the TUI to the dev brain
./exe/anima tui --host localhost:42135

# Optional: enable performance logging for render profiling
./exe/anima tui --host localhost:42135 --debug
# Frame timing data written to log/tui_performance.log
```

Development uses port **42135** so it doesn't conflict with the production brain (port 42134) running via systemd. On first run, `bin/dev` runs `db:prepare` automatically.

Use `./exe/anima` (not `bundle exec anima`) to test local code changes — the exe uses `require_relative` to load local `lib/` directly.

### Running Tests

```bash
bundle exec rspec
```

## License

MIT License. See [LICENSE.txt](LICENSE.txt).
