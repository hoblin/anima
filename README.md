# Anima

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Not a tool. An agent.**

Every AI agent today is a tool pretending to be a person. One brain doing everything. A static context array that fills up and degrades. Sub-agents that start blind and reconstruct context from lossy summaries. A system prompt that says "you are a helpful assistant."

Anima is different. It's built on the premise that if you want an agent — a real one — you need to solve the problems nobody else is solving.

**A brain modeled after biology, not chat.** The human brain isn't one process — it's specialized subsystems on a shared signal bus. Anima mirrors this with a triptych named after the three original Muses: **Aoide** performs (voice, reasoning, tool use), **[Melete](#preparation-as-a-second-brain-melete)** prepares (skills, workflows, goals, naming), **[Mneme](#semantic-memory-mneme)** remembers (summarization, compression, recall). Three processes on the same event bus, each doing one job well. More subsystems are coming.

**Context that never degrades.** Other agents fill a static array until the model gets dumb. Anima assembles a fresh viewport over an event bus every iteration. No compaction. No lossy rewriting. Endless sessions. The [dumb zone](https://github.com/humanlayer/advanced-context-engineering-for-coding-agents/blob/main/ace-fca.md) never arrives — Melete curates what Aoide sees in real time.

**Memory that works like memory.** Other systems bolt on memory as an afterthought — filing cabinets the agent has to consciously open mid-task. It never does; the truck is already moving. Mneme, the muse of memory, runs as a background process on the event bus. She summarizes what's about to leave the viewport. She compresses short-term into long-term, like biological memory consolidating during sleep. She pins critical moments to active goals so exact instructions survive where summaries would lose nuance. And she recalls — automatically, passively — surfacing relevant older memories right after the soul, right before the present. Aoide doesn't decide to remember. She just remembers.

**Sub-agents that know who they are.** When Anima spawns a sub-agent, it starts clean — identity, task, and nothing else. No inherited conversation history means the sub-agent works on its task, not the parent's trajectory. Context flows through explicit messages, not leaked assistant turns.

**A soul the agent writes itself.** Anima's first session is birth. The agent wakes up, explores its world, meets its human, and writes its own identity. Not a personality description in a config file — a living document the agent authors and evolves. Always in context, always its own.

Your agent. Your machine. Your rules. Anima runs locally as a headless Rails 8.1 app with a client-server architecture and terminal UI.

## Table of Contents

- [Architecture](#architecture)
  - [Three Muses](#three-muses)
- [Installation](#installation)
  - [Distribution Model](#distribution-model)
  - [Authentication Setup](#authentication-setup)
- [Agent Capabilities](#agent-capabilities)
  - [Tools](#tools)
  - [Sub-Agents](#sub-agents)
  - [Skills](#skills)
  - [Workflows](#workflows)
  - [MCP Integration](#mcp-integration)
  - [Configuration](#configuration)
- [Design](#design)
  - [Three Layers](#three-layers-mirroring-biology)
  - [Event-Driven Design](#event-driven-design)
  - [Context as Viewport](#context-as-viewport-not-tape)
  - [Brain as Microservices](#brain-as-microservices-on-a-shared-event-bus)
  - [Preparation as a Second Brain (Melete)](#preparation-as-a-second-brain-melete)
  - [Semantic Memory (Mneme)](#semantic-memory-mneme)
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

Anima splits into two processes. The **Brain** is persistent — it handles LLM calls, tool execution, event processing, and state. The **TUI** is a stateless client — it connects via WebSocket, renders events, captures input. If the TUI disconnects, the brain keeps running; when it reconnects, the session resumes with chat history preserved.

Inside the Brain, three independent LLM processes run in parallel on a shared event bus, named after the three original Muses described by Pausanias. They don't call each other — they all react to the same stream of events, and their outputs combine.

### Three Muses

**Aoide — the performer.** The main LLM (Claude Opus 4.6), the muse of voice and performance. Thinks, decides, uses tools, talks to the user. Reads a system prompt assembled fresh every turn (soul + sisters block + snapshots) and a live **viewport** of events from the database — never a static array. Everything the agent outputs is Aoide; her sisters stay silent in her voice.

**Melete — the preparer.** A separate LLM process (Claude Haiku 4.5) that runs as Aoide's subconscious between turns. She observes the conversation and handles everything Aoide shouldn't break flow for: activating relevant skills, managing workflows, tracking goals, naming the session. The first microservice on Anima's event bus — the working proof that background subscribers scale. → [Preparation as a Second Brain (Melete)](#preparation-as-a-second-brain-melete)

**Mneme — the rememberer.** The third muse, running on the same event bus, specializing in one job: making sure nothing important is ever truly lost. She summarizes what's about to leave the viewport, compresses short-term memories into long-term, pins critical events to active goals, and surfaces relevant older context automatically via passive recall. Biology, not a filing cabinet. → [Semantic Memory (Mneme)](#semantic-memory-mneme)

Two more subsystems are designed but not yet implemented: **Thymos** (a hormonal/desire subscriber) and **Psyche** (a coefficient matrix for evolving individuality). Both plug into the same event bus as Melete and Mneme — no orchestrator, no central loop, just more independent subscribers reacting to the same stream.

## Installation

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
├── config.toml      # Brain settings (hot-reloadable)
├── tui.toml         # TUI settings (hot-reloadable)
├── mcp.toml         # MCP server configuration
├── config/
│   └── credentials/   # Rails encrypted credentials (includes AR encryption keys)
├── agents/          # User-defined specialist agents (override built-ins)
├── skills/          # User-defined skills (override built-ins)
├── workflows/       # User-defined workflows (override built-ins)
├── db/              # SQLite databases (production, development, test)
├── log/
└── tmp/
```

Updates: `anima update` — upgrades the gem, merges new config settings into both `config.toml` and `tui.toml` without overwriting customized values, and restarts the systemd service if it's running. Use `anima update --migrate-only` to skip the gem upgrade and only add missing config keys.

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
| `read_file` | Read files with smart truncation and offset/limit paging |
| `write_file` | Create or overwrite files |
| `edit_file` | Surgical text replacement with uniqueness constraint |
| `web_get` | Fetch content from HTTP/HTTPS URLs (HTML → Markdown, JSON → TOON) |
| `spawn_specialist` | Spawn a named specialist sub-agent from the registry |
| `spawn_subagent` | Spawn a generic child session with custom tool grants |
| `think` | Think out loud or silently — reasoning step between tool calls |
| `search_messages` | Keyword sweep across long-term memory (FTS5). Returns ranked snippets with message IDs for drill-down |
| `view_messages` | Fractal window around a past message — full detail at the center, compressed snapshots at the edges |
| `open_issue` | File a self-improvement issue when something is broken, missing, or could be better |
| `mark_goal_completed` | Sub-agent only: signal task completion and deliver results to parent |

Plus dynamic tools from configured MCP servers, namespaced as `server_name__tool_name`.

### Sub-Agents

Sub-agents aren't processes — they're sessions on the same event bus. When a sub-agent spawns, it starts with a clean context: a system prompt (identity + communication instructions), a Goal from the task description, and a single user message containing the task — auto-pinned so it survives viewport eviction. No parent conversation history. Sub-agents inherit the parent shell's working directory at spawn time and use a separate model and token budget (configurable via `subagent_model` and `subagent_token_budget`).

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

Each sub-agent is spawned with a single **Goal** from its task description and a pinned user message containing the task text. When done, the sub-agent calls `mark_goal_completed` to deliver results to the parent — this is the explicit finish line that prevents runaway agents. Sub-agents also get half the main agent's thinking budget to limit scope creep.

Between spawn and completion, sub-agents communicate through natural text — their `agent_message` events route to the parent session automatically, and the parent replies via `@name` mentions. Workers become colleagues.

### Skills

Domain knowledge bundles loaded from Markdown files. Skills provide specialized expertise that Melete activates based on conversation context. Skill content enters the conversation as phantom tool_use/tool_result pairs through the `PendingMessage` promotion flow — the same mechanism used for sub-agent messages. This keeps the system prompt stable for prompt caching while skills flow through the sliding window like regular messages.

- **Built-in skills:** ActiveRecord, Draper decorators, DragonRuby, MCP server, RatatuiRuby, RSpec, GitHub issues
- **User skills:** Drop `.md` files into `~/.anima/skills/` to add custom knowledge
- **Override:** User skills with the same name replace built-in ones
- **Format:** Flat files (`skill-name.md`) or directories (`skill-name/SKILL.md` with `examples/` and `references/`)
- **Viewport deduplication:** Melete's skill catalog excludes skills already visible in the viewport, preventing redundant activation

Active skills are displayed in the TUI HUD panel (toggle with `C-a → h`).

### Workflows

Operational recipes that describe multi-step tasks. Unlike skills (domain knowledge), workflows describe WHAT to do. Melete activates a workflow when she recognizes a matching task and converts the prose into tracked goals. Like skills, workflow content enters the conversation as a `from_melete` phantom pair through the `PendingMessage` flow and rides the viewport until it evicts — there is no explicit deactivation.

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

The active workflow is shown in the TUI HUD panel with a 📜 indicator. The full lifecycle — activation, goal creation, execution, deactivation — is managed by Melete using judgment, not hardcoded triggers.

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

### Configuration

Brain and TUI have separate config files — both hot-reloadable (no restart needed).

**Brain settings** (`~/.anima/config.toml`):

```toml
[llm]
model = "claude-opus-4-6"
fast_model = "claude-haiku-4-5"
max_tokens = 8192
max_tool_rounds = 250
token_budget = 120_000
subagent_model = "claude-sonnet-4-6"
subagent_token_budget = 90_000

[timeouts]
api = 300
command = 30

[melete]
max_tokens = 4096
blocking_on_user_message = true
message_window = 20

[session]
default_view_mode = "basic"
```

**TUI settings** (`~/.anima/tui.toml`):

```toml
[connection]
default_host = "localhost:42134"    # Override per-launch with --host

[chat]
scroll_step = 1
viewport_back_buffer = 3

[theme]
rate_limit_warning = 70             # Yellow at 70%
rate_limit_critical = 90            # Red at 90%
user_message_bg = 22                # 256-color: dark green
assistant_message_bg = 17           # 256-color: dark navy
scrollbar_thumb = "cyan"
border_focused = "yellow"
```

The TUI is a standalone client with zero Rails dependency. Its settings cover connection tuning, scroll behavior, terminal watchdog, theme colors, and performance logging. See `~/.anima/tui.toml` for all available options.

## Design

### Three Layers (mirroring biology)

1. **Cortex (Aoide)** — the main LLM, the muse of performance. Thinking, decisions, tool use. Reads the system prompt (soul + sisters + snapshots) and the event viewport. This layer is fully implemented.

2. **Endocrine system (Thymos)** [planned] — a lightweight background process. Reads recent events. Doesn't respond. Just updates hormone levels. Pure stimulus→response, like a biological gland. Melete is the architectural proof that background subscribers work — Thymos plugs into the same event bus.

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

Events fire, subscribers react, state updates. The system prompt — soul, sisters block, and snapshots — is assembled fresh for each LLM call. Skills, workflows, and goals flow through the message stream as phantom tool pairs instead, keeping the system prompt stable for prompt caching. The agent's identity (soul.md) is always current, never stale.

### Context as Viewport, Not Tape

Most agents treat context as an append-only array — messages go in, they never come out (until compaction destroys them). Anima has no array. There are only events persisted in SQLite, and a **viewport** assembled fresh for every LLM call.

The viewport is a live query, not a log. It walks events newest-first until the token budget is exhausted. Events that fall out of the viewport aren't deleted — they're still in the database, just not visible to the model right now. The context can shrink, grow, or change composition between any two iterations. If Melete marks a large accidental file read as irrelevant, it's gone from the next viewport — tokens recovered instantly.

This means sessions are endless. No compaction. No lossy rewriting. The model always operates in fresh, high-quality context. The [dumb zone](https://github.com/humanlayer/advanced-context-engineering-for-coding-agents/blob/main/ace-fca.md) never arrives. Meanwhile, Mneme runs as a background muse — summarizing evicted events into persistent snapshots so past context is preserved, not destroyed.

Sub-agent viewports use the same mechanism — their own events only, no parent context inheritance. The parent provides context through the task description, and the sub-agent builds its own conversation from a clean slate.

### Brain as Microservices on a Shared Event Bus

The prefrontal cortex doesn't "call" the amygdala. Dozens of specialized subsystems react to the same chemical and electrical signals independently, and their outputs combine — no central coordinator, no blocking RPC, no orchestrator deciding the order of thoughts. Anima mirrors this with an event bus. Melete is the first subscriber that proves the pattern scales; Mneme is the second. Future subscribers plug into the same bus:

```
Event: "tool_call_failed"
  │
  ├── Melete: update goals, check if workflow needs changing
  ├── Mneme: summarize evicted context into snapshot
  ├── Thymos subscriber: frustration += 10 [planned]
  └── Psyche subscriber: update coefficient (this agent handles errors calmly) [planned]

Event: "user_sent_message"
  │
  ├── Melete: activate relevant skills, name session
  ├── Mneme: check viewport eviction, fire if boundary left viewport
  ├── Thymos subscriber: oxytocin += 5 (bonding signal) [planned]
  └── Psyche subscriber: associate emotional state with topic [planned]
```

Each subscriber is a microservice — independent, stateless, reacting to the same event bus. No orchestrator decides what to do. The architecture IS the nervous system.

### Preparation as a Second Brain (Melete)

Every agent today does everything with one brain. Skill selection, workflow tracking, goal management, session naming — all of it competes with the primary task for the same context window and the same attention. Each of these is a micro-task that requires the agent to stop thinking about the real work, do the bookkeeping, and try to pick up where it left off. Flow breaks on every interruption. The full motivation is in [LLMs Have ADHD: Why Your AI Agent Needs a Second Brain](https://blog.promptmaster.pro/posts/llms-have-adhd/).

Melete is the answer: a second LLM process that runs between turns as Aoide's subconscious. She observes the conversation and handles everything Aoide shouldn't break flow for:

- **Skill activation** — recognizes when a domain becomes relevant and activates matching skill content into Aoide's viewport. A skill rides the viewport as a `from_melete` phantom pair until it naturally evicts — there is no deactivation.
- **Workflow management** — recognizes multi-step tasks, activates matching workflows, and tracks their lifecycle from start to finish.
- **Goal tracking** — creates root goals and sub-goals as work progresses, marks them complete, evicts finished goals from context after a configurable message threshold.
- **Session naming** — generates an emoji + short name the moment the topic becomes clear.

Each of these would be a context switch for Aoide — a chore that competes with the primary task. For Melete, they ARE the primary task. Two muses, each in her own flow state.

Goals form a two-level hierarchy (root goals with sub-goals) and are displayed in the TUI HUD. Melete uses a fast model (Claude Haiku 4.5) for speed and runs as a non-persisted "phantom" session: she emits events for activation tools but no trace of her own reasoning lands in the database. Her decisions reach Aoide only through the skills, workflows, goals, and names she leaves behind.

### Semantic Memory (Mneme)

Every AI agent today has the same disability: amnesia. Context fills up, gets compacted, gets destroyed. The agent gets dumber as the conversation gets longer. When the session ends, everything is gone. Some systems bolt on memory as an afterthought — markdown files with procedures for when to save and what format to use. Filing cabinets the agent has to consciously decide to open, mid-task, while in flow. It never does. The truck is already moving.

Mneme is not a filing cabinet. She's *remembering* — the way biological memory works. Continuous, automatic, layered. The third muse running on the same event bus as Aoide and Melete, specializing in one job: making sure nothing important is ever truly lost.

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

**Associative recall** — FTS5 full-text search across the entire message history, across all sessions. Two modes: *passive* recall triggers automatically when goals change — Mneme searches for relevant older context and injects it into the viewport between snapshots and the sliding window as `from_mneme` phantom pairs. Memories surface on their own, right after the soul, right before the present. Aoide doesn't have to decide to remember — the remembering happens around her. *Active* search is available to Aoide through `search_messages(query:)` (keyword sweep across long-term memory) and `view_messages(message_id:)` (fractal window around a specific message — full detail at the center, compressed snapshots at the edges, like eye focus with sharp fovea and blurry periphery).

The difference from every other system: memory isn't a tool the agent uses. It's the substrate the agent thinks in. Every LLM call assembles a fresh viewport where identity comes first, then memories, then the present — the agent always knows who it is, always has access to what it learned, and never has to break flow to make that happen.

### TUI HUD & View Modes

The right-side HUD panel shows session state at a glance: session name, goals (with status icons), active skills, workflow, and sub-agents. Toggle with `C-a → h`; when hidden, the input border shows `C-a → h HUD` as a reminder.

**Braille spinner**: An animated braille character (U+2800-U+28FF) replaces the old "Thinking..." label in both the chat viewport and HUD. Each processing state has a distinct animation pattern — smooth snake rotation for LLM generation, staccato pulse for tool execution, rapid deceleration for interrupting. Sub-agents in the HUD show state-driven icons: `●` (generating, green), `◉` (tool executing, green), `●` (interrupting, red), `◌` (idle, grey).

**Token Economy HUD**: A fixed panel at the bottom of the HUD displays API economics extracted from every Anthropic response:

```
╭ 📊 Token Economy ────────────────────╮
│  5h ░░░░░░░░  1% ➞3h42m              │
│  7d ▓▓▓▓▓▓▓▓ 98%                     │
│  ⚡ ▓▓▓▓▓▓░░ 69%                     │
│  💾 6.3K tokens                      │
│     ⠛⣿⣷⣶⣿⣿⣿⣿⣷⣶⣿⣿⣿           │
│  🟢 Verbose                          │
╰──────────────────────────────────────╯
```

| Row | Description |
|-----|-------------|
| `5h` | 5-hour rate limit utilization with progress bar and reset countdown |
| `7d` | 7-day rate limit utilization with progress bar |
| `⚡` | Cache hit rate — percentage of input tokens served from cache |
| `💾` | Cumulative tokens saved by cache hits |
| `⠛⣿` | Braille sparkline — per-call cache hit history (2 calls per character); drops signal cache busts |
| `🟢` | Connection status and current view mode |

Progress bars are color-coded: green (< 70%), yellow (70-89%), red (>= 90%) for rate limits; inverted for cache hits (green >= 70%, red < 30%). All data comes from Anthropic API response headers and usage objects, broadcast as message metadata via ActionCable.

When content exceeds the panel height, the HUD scrolls. Three input methods:

| Input | Action |
|-------|--------|
| `C-a → →` | Enter HUD focus mode (yellow border) |
| `↑` / `↓` | Scroll one line (when focused) |
| `Page Up` / `Page Down` | Scroll one page (when focused) |
| `Home` / `End` | Jump to top / bottom (when focused) |
| `Escape` or `C-a` | Exit HUD focus mode |
| Mouse wheel over HUD | Scroll without entering focus mode |

**Escape key interrupt:** Press `Escape` while the agent is working to signal an interrupt. Running shell commands cooperatively abort — they receive Ctrl+C and return partial output tagged `Your human wants your attention`, which the LLM sees on the next round and pivots from. The interrupt cascades to active sub-agents.

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
- Melete, muse of practice (skills, workflows, goals, session naming)
- Mneme, muse of memory (eviction-triggered summarization, persistent snapshots, goal-scoped event pinning, associative recall)
- 12 built-in tools + MCP integration (HTTP + stdio transports)
- 7 built-in skills + 13 built-in workflows (user-extensible)
- Sub-agents with isolated context (5 specialists + generic)
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
