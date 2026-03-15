# Anima

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**A personal AI agent that actually wants things.**

Your agent. Your machine. Your rules. Anima is an AI agent with desires, personality, and personal growth — running locally as a headless Rails 8.1 app with a client-server architecture and TUI interface.

## Table of Contents

- [The Problem](#the-problem)
- [The Insight](#the-insight)
- [Core Concepts](#core-concepts)
- [Architecture](#architecture)
- [Agent Capabilities](#agent-capabilities)
  - [Tools](#tools)
  - [Sub-Agents](#sub-agents)
  - [Skills](#skills)
  - [MCP Integration](#mcp-integration)
  - [Analytical Brain](#analytical-brain)
  - [Configuration](#configuration)
- [Design](#design)
  - [Three Layers](#three-layers-mirroring-biology)
  - [Event-Driven Design](#event-driven-design)
  - [Context as Viewport](#context-as-viewport-not-tape)
  - [Brain as Microservices](#brain-as-microservices-on-a-shared-event-bus)
  - [TUI View Modes](#tui-view-modes)
  - [Plugin Architecture](#plugin-architecture)
  - [Semantic Memory](#semantic-memory-mneme)
- [Analogy Map](#analogy-map)
- [Emergent Properties](#emergent-properties)
- [Frustration: A Worked Example](#frustration-a-worked-example)
- [Open Questions](#open-questions)
- [Prior Art](#prior-art)
- [Status](#status)
- [Development](#development)
- [License](#license)

## The Problem

Current AI agents are reactive. They receive input, produce output. They don't *want* anything. They don't have moods, preferences, or personal growth. They simulate personality through static prompt descriptions rather than emerging it from dynamic internal states.

## The Insight

The human hormonal system is, at its core, a prompt engineering system. A testosterone spike is a LoRA. Dopamine is a reward signal. The question isn't "can an LLM want?" but "can we build a deep enough context stack that wanting becomes indistinguishable from 'real' wanting?"

And if you think about it — what is "real" anyway? It's just a question of how deep you look and what analogies you draw. The human brain is also a next-token predictor running on biological substrate. Different material, same architecture.

## Core Concepts

### Desires, Not States

This is not an emotion simulation system. The key distinction: we don't model *states* ("the agent is happy") or *moods* ("the agent feels curious"). We model **desires** — "you want to learn more", "you want to reach out", "you want to explore".

Desires exist BEFORE decisions, like hunger exists before you decide to eat. The agent doesn't decide to send a photo because a parameter says so — it *wants* to, and then decides how.

### The Thinking Step

The LLM's thinking/reasoning step is the closest thing to an internal monologue. It's where decisions form before output. This is where desires should be injected — not as instructions, but as a felt internal state that colors the thinking process.

### Hormones as Semantic Tokens

Instead of abstract parameter names (curiosity, boredom, energy), we use **actual hormone names**: testosterone, oxytocin, dopamine, cortisol.

Why? Because LLMs already know the full semantic spectrum of each hormone. "Testosterone: 85" doesn't just mean "energy" — the LLM understands the entire cloud of effects: confidence, assertiveness, risk-taking, focus, competitiveness. One word carries dozens of behavioral nuances.

This mirrors how text-to-image models process tokens — a single word like "captivating" in a CLIP encoder carries a cloud of visual meanings (composition, quality, human focus, closeup). Similarly, a hormone name carries a cloud of behavioral meanings. Same architecture, different domain:

```
Text → CLIP embedding → image generation
Event → hormone vector → behavioral shift
```

### The Soul as a Coefficient Matrix

Two people experience the same event. One gets `curiosity += 20`, another gets `anxiety += 20`. The coefficients are different — the people are different. That's individuality.

The soul is not a personality description. It's a **coefficient matrix** — a table of stimulus→response multipliers. Description is consequence; numbers are cause.

And these coefficients are not static. They **evolve through experience** — a child who fears spiders (`fear_gain: 0.9`) can become an entomologist (`fear_gain: 0.2, curiosity_gain: 0.7`). This is measurable, quantifiable personal growth.

### Multidimensional Reinforcement Learning

Traditional RL uses a scalar reward signal. Our approach produces a **hormone vector** — multiple dimensions updated simultaneously from a single event. This is closer to biological reality and provides richer behavioral shaping.

The system scales in two directions:
1. **Vertically** — start with one hormone (pure RL), add new ones incrementally. Each hormone = new dimension.
2. **Horizontally** — each hormone expands in aspects of influence. Testosterone starts as "energy", then gains "risk-taking", "confidence", "focus".

Existing RL techniques apply at the starting point, then we gradually expand into multidimensional space.

## Architecture

```
Anima (Ruby, Rails 8.1 headless)
├── Nous         — LLM integration (cortex, thinking, decisions, tool use)
├── Analytical   — subconscious background brain (naming, skills, goals)
├── Skills       — domain knowledge bundles (Markdown, user-extensible)
├── MCP          — external tool integration (Model Context Protocol)
├── Sub-agents   — autonomous child sessions (specialists + generic)
├── Thymos       — hormonal/desire system (stimulus → hormone vector) [planned]
├── Mneme        — semantic memory (QMD-style, emotional recall) [planned]
└── Psyche       — soul matrix (coefficient table, evolving) [planned]
```

### Runtime Architecture

```
Brain Server (Rails + Puma)              TUI Client (RatatuiRuby)
├── LLM integration (Anthropic)          ├── WebSocket client
├── Agent loop + tool execution          ├── Terminal rendering
├── Analytical brain (background)        └── User input capture
├── Skills registry + activation
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
| LLM integration | Anthropic API (Claude Sonnet 4, Claude Haiku 4.5) |
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
├── config/
│   ├── credentials/ # Rails encrypted credentials per environment
│   └── anima.yml    # Placeholder config
├── config.toml      # Main settings (hot-reloadable)
├── mcp.toml         # MCP server configuration
├── agents/          # User-defined specialist agents (override built-ins)
├── skills/          # User-defined skills (override built-ins)
├── db/              # SQLite databases (production, development, test)
├── log/
└── tmp/
```

Updates: `gem update anima-core` — next launch runs pending migrations automatically.

### Authentication Setup

Anima uses your Claude Pro/Max subscription for API access. You need a setup-token from [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code).

1. Run `claude setup-token` in a terminal to get your token
2. In the TUI, press `Ctrl+a → a` to open the token setup popup
3. Paste the token and press Enter — Anima validates it against the Anthropic API and saves it to encrypted credentials

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
| `web_get` | Fetch content from HTTP/HTTPS URLs |
| `spawn_specialist` | Spawn a named specialist sub-agent from the registry |
| `spawn_subagent` | Spawn a generic child session with custom tool grants |
| `return_result` | Sub-agents only — deliver results back to parent |

Plus dynamic tools from configured MCP servers, namespaced as `server_name__tool_name`.

### Sub-Agents

Two types of autonomous child sessions:

**Named Specialists** — predefined agents with specific roles and tool sets, defined in `agents/` (built-in or user-overridable):

| Specialist | Role |
|-----------|------|
| `codebase-analyzer` | Analyze implementation details |
| `codebase-pattern-finder` | Find similar patterns and usage examples |
| `documentation-researcher` | Fetch library docs and provide code examples |
| `thoughts-analyzer` | Extract decisions from project history |
| `web-search-researcher` | Research questions via web search |

**Generic Sub-agents** — child sessions that inherit parent context and run autonomously with custom tool grants.

Sub-agents run as background jobs, return results via `return_result`, and appear in the TUI session picker under their parent.

### Skills

Domain knowledge bundles loaded from Markdown files. Skills provide specialized expertise that the analytical brain activates and deactivates based on conversation context.

- **Built-in skills:** ActiveRecord, Draper decorators, DragonRuby, MCP server, RatatuiRuby, RSpec, GitHub issues
- **User skills:** Drop `.md` files into `~/.anima/skills/` to add custom knowledge
- **Override:** User skills with the same name replace built-in ones
- **Format:** Flat files (`skill-name.md`) or directories (`skill-name/SKILL.md` with `examples/` and `references/`)

Active skills are displayed in the TUI info panel.

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

anima mcp secrets set linear_api_key=sk-xxx # Store secret in encrypted credentials
anima mcp secrets list                      # List secret names (not values)
anima mcp secrets remove linear_api_key     # Remove secret
```

Secrets are stored in Rails encrypted credentials and interpolated via `${credential:key_name}` syntax in any TOML string value.

### Analytical Brain

A subconscious background process that observes the main conversation and performs maintenance:

- **Session naming** — generates emoji + short name when topic becomes clear
- **Skill activation** — activates/deactivates domain skills based on context
- **Goal tracking** — creates root goals and sub-goals as the conversation progresses, marks them complete

Goals form a two-level hierarchy (root goals with sub-goals) and are displayed in the TUI. The analytical brain uses a fast model (Claude Haiku 4.5) for speed and runs as a non-persisted "phantom" session.

### Configuration

All tunable values are exposed through `~/.anima/config.toml` with hot-reload (no restart needed):

```toml
[llm]
model = "claude-sonnet-4-20250514"
fast_model = "claude-haiku-4-5-20251001"
max_tokens = 16384
token_budget = 190000

[timeouts]
api = 120
command = 30

[analytical_brain]
max_tokens = 4096
blocking_on_user_message = true
event_window = 30

[session]
name_generation_interval = 3
```

## Design

### Three Layers (mirroring biology)

1. **Endocrine system (Thymos)** — a lightweight background process. Reads recent events. Doesn't respond. Just updates hormone levels. Pure stimulus→response, like a biological gland.

2. **Homeostasis** — persistent state (SQLite). Current hormone levels with decay functions. No intelligence, just state that changes over time.

3. **Cortex (Nous)** — the main LLM. Reads hormone state transformed into **desire descriptions**. Not "longing: 87" but "you want to see them". The LLM should NOT see raw numbers — humans don't see cortisol levels, they feel anxiety.

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

Events fire, subscribers react, state updates, the cortex (LLM) reads the resulting desire landscape. The system prompt is assembled separately for each LLM call — it is not an event.

### Context as Viewport, Not Tape

There is no linear chat history. There are only events attached to a session. The context window is a **viewport** — a sliding window over the event stream, assembled on demand for each LLM call within a configured token budget.

Currently uses a simple sliding window (newest events first, walk backwards until budget exhausted). Future versions will add associative recall from Mneme.

### Brain as Microservices on a Shared Event Bus

The human brain isn't a single process — it's dozens of specialized subsystems communicating through shared chemical and electrical signals. The prefrontal cortex doesn't "call" the amygdala. They both react to the same event independently, and their outputs combine.

Anima mirrors this with an event-driven architecture:

```
Event: "tool_call_failed"
  │
  ├── Thymos subscriber: frustration += 10
  ├── Mneme subscriber: log failure context for future recall
  └── Psyche subscriber: update coefficient (this agent handles errors calmly → low frustration_gain)

Event: "user_sent_message"
  │
  ├── Thymos subscriber: oxytocin += 5 (bonding signal)
  ├── Thymos subscriber: dopamine += 3 (engagement signal)
  └── Mneme subscriber: associate emotional state with conversation topic
```

Each subscriber is a microservice — independent, stateless, reacting to the same event bus. No orchestrator decides "now update frustration." The architecture IS the nervous system.

### TUI View Modes

Three switchable view modes let you control how much detail the TUI shows. Cycle with `Ctrl+a → v`:

| Mode | What you see |
|------|-------------|
| **Basic** (default) | User + assistant messages. Tool calls are hidden but summarized as an inline counter: `🔧 Tools: 2/2 ✓` |
| **Verbose** | Everything in Basic, plus timestamps `[HH:MM:SS]`, tool call previews (`🔧 bash` / `$ command` / `↩ response`), and system messages |
| **Debug** | Full X-ray view — timestamps, token counts per message (`[14 tok]`), full tool call args, full tool responses, tool use IDs |

View modes are implemented via Draper decorators that operate at the transport layer. Each event type has a dedicated decorator (`UserMessageDecorator`, `ToolCallDecorator`, etc.) that returns structured data — the TUI renders it. Mode is stored on the `Session` model server-side, so it persists across reconnections.

### Plugin Architecture

Both tools and feelings are distributed as gems on the event bus:

```bash
anima add anima-tools-filesystem
anima add anima-tools-shell
anima add anima-feelings-frustration
```

Tools provide MCP capabilities. Feelings are event subscribers that update hormonal state. Same mechanism, different namespace. Currently tools are built-in; plugin extraction comes later.

### Semantic Memory (Mneme)

Hormone responses shouldn't be based only on the current stimulus. With semantic memory (inspired by [QMD](https://github.com/tobi/qmd)), the endocrine system can recall: "Last time this topic came up, curiosity was at 95 and we had a great evening." Hormonal reactions colored by the full history of experiences — like smelling mom's baking and feeling a wave of oxytocin. Not because of the smell, but because of the memory attached to it.

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

**Agent with autonomous capabilities.** The conversational agent works end-to-end with: event-driven architecture, LLM integration with 8 built-in tools, MCP integration (HTTP + stdio transports), skills system with 7 built-in knowledge domains, analytical brain (session naming, skill activation, goal tracking), sub-agents (5 named specialists + generic spawning), sliding viewport context assembly, persistent sessions with sub-agent hierarchy, client-server architecture with WebSocket transport, graceful reconnection, three TUI view modes (Basic/Verbose/Debug), and hot-reloadable TOML configuration.

The hormonal system (Thymos, feelings, desires), semantic memory (Mneme), and soul matrix (Psyche) are designed but not yet implemented — they're the next layer on top of the working agent.

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
```

Development uses port **42135** so it doesn't conflict with the production brain (port 42134) running via systemd. On first run, `bin/dev` runs `db:prepare` automatically.

Use `./exe/anima` (not `bundle exec anima`) to test local code changes — the exe uses `require_relative` to load local `lib/` directly.

### Running Tests

```bash
bundle exec rspec
```

## License

MIT License. See [LICENSE.txt](LICENSE.txt).
