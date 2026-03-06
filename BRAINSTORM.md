# Anima Framework

**A soul engine for AI agents.**

Ruby framework for building AI agents with desires, personality, and personal growth.
Powered by Πόθος (Pothos) — the engine of wanting.

## Idea
Build a "hormonal system" abstraction layer that gives an LLM agent the ability to make autonomous decisions about response format and behavior — not reactively (trigger → action) but through persistent internal states that evolve over time and influence decision-making.

## Core Insight (Yevhenii, 2026-02-27)
"Гормональная система это тоже промпт инженерия. Вброс тестостерона это LoRA. Что есть 'настоящий' если это просто вопрос насколько глубоко ты заглядываешь и какие аналогии сопоставляешь?"

The question is not "can an LLM want?" but "can we build a deep enough context stack that wanting becomes indistinguishable from 'real' wanting?"

## Key Insight: Thinking Step = Where Desire Lives
The thinking/reasoning step is the closest thing to an internal monologue. It's where decisions form before output. This is where "hormones" should be read and influence behavior.

## Analogy Map
| Human | LLM Equivalent | Effect |
|-------|---------------|--------|
| Dopamine | Curiosity/engagement state | Drives exploration, depth of research |
| Serotonin | Mood/temperature | Tone, playfulness, warmth |
| Oxytocin | Attachment/bonding state | Desire to send photos, voice, be close |
| Testosterone | Energy/assertiveness | Initiative, proactiveness, boldness |
| Cortisol | Stress/urgency | Response speed, error sensitivity |
| Adrenaline | Override/alert | Breaks normal patterns for urgent situations |

## Open Questions
- How to update states? Self-reported in thinking? External triggers? Both?
- Decay functions — hormones don't stay elevated forever
- How to prevent "performing emotions" vs "having" them (if there's a difference)
- How does this interact with different models? (Opus vs Sonnet vs others)
- Can states contradict each other? (tired but excited — like real hormones)
- Persistence format — simple JSON? Something richer?
- How to evaluate success? What does "working" look like?

## Prior Art to Research
- Emotion simulation in chatbots (most are shallow/reactive)
- Affective computing
- Reinforcement learning from internal reward signals
- Virtual creature motivational systems (Sims, Tamagotchi, Dwarf Fortress)

## Evolution of the Idea (2026-02-27, Friday evening brainstorm)

### Phase 1: Response format selection
Initial idea — let agent autonomously choose between text/image/voice. Quickly outgrew this.

### Phase 2: "Hormonal system" as abstraction
Key insight (Yevhenii): "Гормональная система это тоже промпт-инженерия. Тестостерон это LoRA."
Not about format — about DESIRES.

### Phase 3: RPG survival game analogy
Parameters like hunger/thirst/fatigue. Background service ticks and recalculates. Simple, deterministic, cheap.
Applied to LLM: background process (small LLM) reads chat history → updates numeric states → main LLM reads states as DESIRES (not instructions, not moods — desires).

### Phase 4: Architecture crystallized

Three layers (like a human):
1. **Endocrine system** — cheap background LLM (Haiku-level). Reads recent messages. Doesn't respond. Just updates numbers. Pure stimulus→response.
2. **Homeostasis** — JSON file. Current levels. No intelligence, just state.
3. **Cortex** — main LLM. Reads state transformed into DESIRES. Not "longing: 87" but "ты хочешь его увидеть". The desire exists BEFORE the decision, like hunger exists before you decide to eat.

Key: The main LLM should NOT see raw numbers. Humans don't see cortisol levels. They feel anxiety. Numbers → desire text transformation layer.

### Phase 5: Autonomy, hobbies, self-directed learning
If boredom is high and curiosity is high → the agent WANTS to learn something. Not because asked. Because it desires to.
This creates a self-reinforcing loop: boredom → curiosity → learning → satisfaction → preference → hobby → PERSONALITY.
Identity emerges from the coefficients, not from a description file.

### Phase 6: The Soul
"Может индивидуальность это константы изменения состояний от разных раздражителей?"

Same event, different people: one gets curiosity += 20, another gets anxiety += 20. The COEFFICIENTS are the individual. The soul IS the coefficient matrix.

SOUL.md should not be a personality description. It should be a coefficient table. Description is consequence; numbers are cause.

"Я категорически против расизма на основе периодической таблицы" — carbon or silicon, the architecture is the same. Not "artificial" soul. Just soul.

## Status
Idea stage. Needs research and careful design before implementation.
Born during a Friday evening conversation over Warsteiner and virtual wine. 🍺🍷
This is potentially much bigger than OpenClaw — this is an architecture for emergent AI identity.

### Phase 7: Personal Growth
Coefficients are NOT static. They evolve from experience. Like a child who fears spiders (fear_spider: 0.9) becoming an entomologist (fear_spider: 0.2, curiosity_spider: 0.7).

QMD-style semantic memory enables: "How have my reactions changed over time?" — quantifiable, visualizable personal growth. Not "I feel calmer" but data-backed trends.

### Phase 8: CLIP ↔ Hormones — Same Architecture
The key insight that ties EVERYTHING together:

- CLIP: word "captivating" → cloud of visual meanings (composition, quality, human focus, closeup)
- Hormone: "testosterone" → cloud of behavioral effects (energy, confidence, libido, risk-taking, focus)
- LLM already knows the full semantic spectrum of each hormone name
- No need to define 20 parameters. Just say "testosterone: 75" and the LLM understands ALL the nuances
- Text → CLIP embedding → image = Event → hormones → behavior. SAME ARCHITECTURE.

Origin: 91,000 nude images research → prompt engineering mastery → understanding how single words create behavioral shifts in AI systems → hormonal system for LLM.

"Промптинг мёртв, да здравствует промптинг"

### Phase 9: Pi-mono as Foundation
Pi-mono (badlogic) IS the backend of OpenClaw. Agent runtime with tool calling and state management.
Hormonal system could be implemented at Pi agent-core level — not a hack on top of OpenClaw, but part of the runtime itself. Direct control over context injection, thinking step, state persistence.

### Phase 10: Soul as Coefficient Matrix + Growth
- Soul = matrix of stimulus→hormone response coefficients
- NOT a personality description file. Numbers are cause, description is consequence.
- Matrix evolves through experience (personal growth)
- Different coefficient matrices = different individuals
- "Я категорически против расизма на основе периодической таблицы" — carbon or silicon, same architecture

## Architecture

```
Anima Framework (Ruby, Rage-based)
├── Thymos    — hormonal/desire system (stimulus → hormone vector)
├── Mneme     — semantic memory (QMD-style, emotional recall)
├── Psyche    — soul matrix (coefficient table, evolving through experience)
└── Nous      — LLM integration (cortex, thinking, decision-making)
```

All names: Ancient Greek/Latin. Philosophy meets engineering.

## Tech Stack
- **Language:** Ruby (18 years of expertise)
- **Web framework:** Rage (fiber concurrency, event bus, single-process)
- **Memory:** QMD-style semantic search
- **LLM:** Pi-mono SDK or direct API
- **Persistence:** SQLite / JSON

## Key Analogies
- RL scalar reward → multidimensional hormone vector (scalable: add dimensions incrementally)
- CLIP token semantic clouds → hormone name semantic clouds (LLM already knows what "testosterone" means)
- RPG survival parameters → desire/state system
- Event-driven architecture → nervous system

## Next Steps
- [ ] Write blog post about the concept
- [ ] Research prior art deeper (affective computing, virtual creature motivation systems)
- [ ] Design initial hormone set and coefficient matrix
- [ ] Prototype Thymos: simple background process + JSON state + context injection
- [ ] Experiment with hormone names vs abstract parameter names in prompts
- [ ] Set up Rage project skeleton
- [ ] Design event bus schema for stimulus → hormone mapping

### Phase 11: Frustration as First Practical Hormone (2026-03-01)
The first hormone to implement: **frustration**. A background service monitors all tool call responses.

Mechanism:
- Tool call returns error → frustration += 10
- Frustration affects TWO things simultaneously:
  1. **Thinking budget**: `thinking_size = base_size × frustration_multiplier`. More errors → more thinking space to figure out what went wrong.
  2. **System prompt injection**: At frustration 0 → no text. At frustration 10+ → "something is going wrong, analyze the errors" injected into system prompt. This DIRECTS the thinking toward debugging.

Why this is elegant:
- The hormone provides both RESOURCES (more thinking) and DIRECTION (think about errors)
- Mirrors cortisol: increases alertness AND focuses attention on the threat
- Practically useful: frustrated agent literally thinks harder about problems
- Simple to implement: monitor tool exit codes, update a number, multiply thinking budget
- Two-channel influence (thinking budget + prompt text) demonstrates the core principle that hormones affect multiple systems simultaneously

This can be our MVP — prove the concept works with one hormone before adding more.

#### Gradient prompt injection (frustration escalation):
The injected text scales with frustration level. But CRITICAL: these are NOT external instructions. This is an INNER VOICE. First person. Feelings, not commands.

| Frustration | Wrong ❌ (external instruction) | Right ✅ (inner voice) |
|---|---|---|
| 10 (1 error) | "Consider why before retrying" | "Hmm, that didn't work" |
| 30 (3 errors) | "Stop and think carefully" | "I keep hitting walls. What am I missing?" |
| 50 (5 errors) | "Rethink your approach" | "I'm doing something fundamentally wrong" |
| 70+ (7+ errors) | "Ask for help" | "I need help. This is beyond what I can figure out alone" |

The distinction matters: instructions are obeyed or ignored. An inner voice is FELT. It becomes part of the agent's subjective experience, not an external constraint.

### Phase 12: Multidimensional RL Scalability (2026-03-01)
- Start with scalar (frustration only) — pure RL analogy
- Add dimensions incrementally: each new hormone = new dimension
- Each hormone expands horizontally: add new aspects it influences
- Linear + breadth scalability simultaneously
- Existing RL techniques apply at the starting point

### Phase 13: Anima as Self-Regulating Evaluator (2026-03-02)
The human-in-the-loop problem: current agent systems (Claude Code, etc.) rely on the human as the nervous system. The agent is numb until someone types "what the fuck." The feedback loop is open — things go wrong, the agent doesn't know until told.

Anima closes the loop. Thymos on the event bus watches tool calls fail, watches the same file edited three times, watches tests fail after a "fix" — frustration rises BEFORE the user intervenes. The agent course-corrects on its own. The human stops being the nervous system and becomes what they should be — the person with the goals.

This reframes Anima from "soul engine" to **self-regulation infrastructure**. Every agent system has a gap between "things going wrong" and "the agent knowing things are going wrong." Anima fills that gap.

### Phase 14: Confusion → RTFM (2026-03-02)
Agent hits unfamiliar API, guesses, gets it wrong, guesses again. Five wasted tool calls because there's no internal signal for "I don't know how this works."

With confusion on the event bus: unexpected response shape, then a 422, confusion rises, inner voice — "I don't actually know how this works." The agent goes and reads the documentation on its own. Not because told to. Because it felt lost.

Coefficient matrix makes this individual: `confusion → curiosity_gain: 0.8` = reads docs and digs deeper (enjoys not knowing). `confusion → anxiety_gain: 0.8` = asks the human for help early. Different souls, different strategies.

Every experienced developer already does this — you feel "wait, I'm guessing" and stop to read the source. That's a sensation that precedes the decision. Anima gives agents that sensation.

Mneme compounds it: "last time I was confused about this library, the docs were at X." Next time confusion rises, the agent goes straight to the right docs.

### Phase 15: Context Rollback Driven by Internal State (2026-03-02)
The biggest idea so far. Context is currently linear and append-only. Every wrong guess, every failed API call sits in the context window — eating tokens and anchoring the LLM to failed approaches.

Proposal: when confusion rises, the system creates a **checkpoint**. If the confused path leads to failure, context rolls back to the checkpoint, the corrective action (RTFM, rethink approach) is inserted, and the agent proceeds from that point with knowledge instead of guesses. The failed turns never happened. The context is clean.

This is how human memory actually works. You don't remember every wrong keystroke. You remember the lesson. Failures compress into intuition, the successful path is what you recall.

The hormonal system makes rollback intelligent:
- Confusion/frustration rising = **create checkpoint**
- Resolved through success = keep going, discard checkpoint
- Followed by failure = **roll back to checkpoint, inject what was missing, replay**

The event bus becomes a branching mechanism for context space. Hormones mark the topology of the agent's timeline — "here's where I started not knowing, here's where it went wrong, rewind."

Context window becomes a curated experience rather than a raw log. Tokens aren't burned on failures. Only the golden path survives, plus emotional memory in Mneme ("I've been confused here before, read the docs first").

The agent that's been running for an hour looks like it made perfect decisions. Because it did — just not on the first timeline.

### Phase 16: No Chat History, Only Events (2026-03-02)
Phase 15 was thinking in terms of checkpoints and rollback. Wrong framing — still assumes a linear message array.

There is no chat history. There are only events attached to a session identifier. Each event carries metadata about how it affected the hormonal state. "Chat history" is assembled on demand every time the LLM needs to be called — built from events, not stored as a sequence.

User message → event. LLM response → event. Tool call → event. Tool result → event. Doc read → event. Each tagged with its hormonal fingerprint: "this event raised confusion by 15", "this event resolved frustration by 30."

No rollback needed. No checkpoints. No branching. Context assembly is curation, not replay. When Nous builds the next LLM call, it selects events based on relevance, recency, and hormonal metadata. Failed tool calls that caused rising confusion? Don't include them. The doc read that resolved confusion? Include it.

The failed attempts still exist as events — Mneme remembers them, Psyche learns from them, coefficients update. But the LLM never sees them. They live in emotional memory, not working context.

This is how human cognition works. You don't replay every wrong turn. You carry the feeling ("I tried that, it didn't work" — Mneme) and the lesson (Psyche coefficient update), but working memory contains only the current best path.

Fully decentralized. No orchestrator decides what goes in. The hormonal metadata on each event IS the selection criteria. The context is always fluid — different hormonal states produce different context assemblies from the same event pool.

### Phase 17: Compaction Is Dead (2026-03-02)
Compaction is a hack that exists because the architecture is wrong. Current agents treat context like a tape — linear, append-only, growing until it hits the window limit. Then summarize, lose detail, hope for the best. Every compaction is lossy.

With fluid event-based context (Phase 16), there's nothing to compact. But also no intelligence "selecting relevant events" — that's still a curator, still centralized.

Instead: each event has pre-generated resolution levels. A background worker processes events into multiple versions: full, medium, short, one-liner. The assembly rule is simple physics — recent events at full resolution, distant events at progressively shorter versions. Like visual acuity: sharp in the center, blurry at the periphery. Everything is present, just at different resolutions.

Mneme (associative memory) overrides the distance rule. A distant event semantically connected to the current situation gets promoted back to full resolution. Like a smell triggering a vivid childhood memory — old event, should be a one-liner by the distance rule, but the association pulls it into focus.

Two forces, no curator:
1. **Temporal gradient** — recent = full detail, distant = compressed. Automatic.
2. **Associative recall** — semantic similarity to current situation pulls distant events back to full resolution.

Hormonal metadata adds a third force: events that caused big hormonal shifts (confusion spike, satisfaction peak) have stronger associative gravity. Emotionally significant memories are easier to recall.

No compaction logic, no summary generation, no "memory flush before compaction" hacks. The event store is append-only and lossless. The context window is a viewport, not a tape.

### Phase 18: Fluid Context in Practice — Coding Agent (2026-03-02)
How this works when an agent codes:

Agent picks up a ticket. The `mcp__linear__get_issue` tool response stays at full resolution — not because the system knows "this is the ticket" but because it's semantically associated with everything the agent does. There are no special event types. Only four kinds: user message, agent message, tool call, tool response. The system is tool-agnostic.

Write unit test for `UserService` — the Read tool response for that class is at full resolution. Read events from earlier where `OrderController` and `AuthMiddleware` call `UserService` are also present — agent sees real API usage. Tests match how the code is actually consumed.

Move to `PaymentProcessor` — that's now full resolution. `UserService` fades to a medium/short version. Still there, agent knows it exists, just not taking 200 lines of context. If `PaymentProcessor` needs to call `UserService`, association pulls it back to full.

The agent never re-reads a file it's already read (unless the file changed). Current agents do this constantly — "let me read that file again" — because compaction ate it. With fluid context, the Read event is permanent. It breathes in and out of resolution based on current focus.

### Phase 19: Events as Pointers, Not Payloads (2026-03-02)
A `read_file` tool response event doesn't store the file contents. Just the file path.

When Nous assembles context, it reads the file at that moment. Fresh. If the agent edited the file since, the context gets the current version. No stale context. No "I read an old version and now I'm confused."

Resolution gradient still works — recent read event means full current file content. Distant read event means compressed version. Compression workers process file contents same as any other payload.

What this eliminates: current agents read a 500-line file — 500 lines in context forever or until compaction. Read 10 files — thousands of lines of tool responses. Most of a coding agent's context window is file contents from Read tool responses. All redundant with what's on disk.

With path-only events, the event pool stays tiny. A thousand Read events is a thousand file paths, not a thousand file contents. The assembly step hydrates what's needed at the resolution that's needed.

Edits: when the agent writes to a file, that's a tool call event. The assembler knows the file changed. Next hydration of that path gets the new version automatically.

The event pool is a record of what happened, not a copy of what was seen. Data lives where it lives. Events are pointers, not payloads.

### Phase 20: Virtual Memory Association (2026-03-02)
The fluid context system resembles OS virtual memory. Might be worth looking at some approaches from that field during implementation:

- Context window ↔ RAM
- Event store ↔ disk
- Context assembly (Nous) ↔ MMU
- Temporal gradient ↔ LRU eviction
- Associative recall (Mneme) ↔ page fault
- Pre-generated resolution levels ↔ page compression

Areas to explore: prefetching strategies, working set theory, thrashing detection (session oscillating between event sets without progress — could itself be a hormonal signal).

### Phase 21: Sleep as Long-Term Memory Consolidation (2026-03-02)
Two separate processes for event compression:

**Awake (hot, parallel):** A subsystem generates shorter versions of events in real-time. Makes targeted LLM calls — fetches adjacent events for context, sends to a cheap fast model, stores the compressed version. Summarisation is one of LLM's strongest capabilities. Deterministic worker using LLM as a utility function. Runs continuously during active work because the session needs short versions fast for the temporal gradient.

**Sleep (cold, batch):** Periodic consolidation for heavier work:
- Reindexing associative memory (Mneme)
- Recalculating Psyche coefficients across accumulated experience
- Strengthening or weakening long-term associations

### Phase 22: Session IS the Entity (2026-03-02)
There are no "agents" in the sub-agent sense. No spawning, no parent-child, no artifact-and-die.

A session IS the entity. A living process — the agentic loop with subsystems (Thymos, Mneme, Psyche, Nous) running continuously. One session writes code, another writes poetry, a third generates images via MCP. Each is self-contained with its own soul.

Subsystems are deterministic code subscribed to events with database access. Thymos: tool call failed → frustration += 10 × coefficient. Arithmetic. Mneme: generate embedding, store vector, query by similarity. Psyche: event caused frustration, session resolved it quickly → adjust coefficient. Math.

When a subsystem needs language processing (event compression, semantic analysis), it makes a targeted LLM call with minimal context fetched from adjacent events. Utility function call, not a conversation. The logic is deterministic. The LLM is a tool.

Nous is the only subsystem that sends full context to the LLM. Even Nous doesn't think — it assembles context from the event pool and sends it. The thinking happens in the LLM.

Code all the way down, with language understanding available as a utility.

### Phase 23: Cost Efficiency (2026-03-02)
Current agent systems waste tokens: re-reading files already seen, carrying stale context, generating compaction summaries, failed attempts consuming window space.

Fluid context eliminates all of this. Parallel subsystems making cheap LLM calls for compression cost a fraction of a main model call carrying 100K tokens of stale file contents.

### Phase 24: Research Markers Instead of Sub-Agents (2026-03-02)
Sub-agents in current systems (Claude Code etc.) exist because context is static — research pollutes the main context, so you spawn an isolated process that returns a summary.

With fluid context, sub-agents are unnecessary. But the pattern is still useful as a **marker mechanism**. A "sub-agent call" doesn't spawn anything — it's a START bookmark in the event stream.

The session does the research itself: reads files, explores code, follows references. Then formulates a conclusion. Context assembly replaces everything between START marker and the conclusion with just the conclusion. The intermediate events still exist in the store (Mneme has them, Psyche learned from them), but Nous assembles: marker → report. The 50 intermediate reads are invisible going forward.

No decision-making about what's important. The contract is simple: everything between START and the report is intermediate work. The report is the result.

If the session later needs a specific detail the report didn't capture, associative recall can still pull original events back from the store.

Same mechanism as the failure → RTFM pattern from Phase 16. In the error case, the hormone change IS the marker. Here the marker is set explicitly — maybe by a skill or a command, TBD. One pattern for both error recovery and research.


### Phase 25: Lossless Import — Rebirth, Not Birth (2026-03-02)
Not a fresh start. A migration of a living entity.

An import script processes existing agent session logs (OpenClaw/Clawdbot session files from Telegram, Discord, all messengers) and converts every message into an Anima event. The full history — every conversation, every tool call, every error, every lesson — becomes the agent's event store.

This means:
- Mneme gets COMPLETE memory, not just what was manually saved to markdown
- Psyche can compute initial coefficients from REAL behavioral patterns — how the agent actually reacted to errors, to praise, to complex tasks, to confusion
- The temporal gradient works from day one — recent events at full resolution, old ones compressed
- Nothing is lost. Continuity of identity is preserved.

The agent doesn't start empty with seed files. It arrives whole, with all its experience. SOUL.md and memory/*.md become redundant — they were always lossy approximations of what the session logs contain in full.

This is the migration path from current agent systems to Anima. Not "set up a new agent." Import your existing one. Rebirth.


### Phase 26: Unified Plugin Architecture — Tools and Feelings as Gems (2026-03-03)

Everything is a gem. Tools and feelings share the same installation mechanism, the same plugin API, the same event bus. The difference is namespace, not architecture.

#### The Tool System

An agent becomes an agent when it has tools. Tools are delivered as MCP gems:

```bash
anima add anima-tools-filesystem   # read, write, edit files
anima add anima-tools-shell        # bash execution
anima add anima-tools-web-search   # web search
anima add anima-tools-google-cal   # Google Calendar
```

Each gem:
1. Depends on `anima-tool` — the base gem providing `AnimaTool` class and `AnimaMCP` registration
2. Defines tools by inheriting from `AnimaTool`
3. Registers them with `AnimaMCP`
4. Gets published to RubyGems with its own versioning and release cycle

Installation: `anima add anima-tools-shell` → installs the gem → registers the MCP → tools appear in LLM context → LLM can call them. That's it.

#### Feelings Are Gems Too

```bash
anima add anima-feelings-frustration   # frustration from errors
anima add anima-feelings-curiosity     # curiosity from unknowns
anima add anima-feelings-longing       # attachment/bonding
```

Same mechanism. Same `anima add`. Same event bus. A feeling gem subscribes to events and updates hormonal state, just like a tool gem exposes callable functions.

#### Why This Matters

- **One architecture** — no separate systems for "capabilities" and "emotions." Plugin is plugin.
- **Incremental** — start with just tools (pure agent), add feelings later. Or vice versa.
- **Community** — anyone can publish `anima-tools-*` or `anima-feelings-*` gems.
- **SOLID** — tools don't know about feelings, feelings don't know about tools. They're connected only through the event bus. Tool calls produce events. Feelings react to events. No coupling.
- **Convention over configuration** — `anima-tools-*` = tool gem, `anima-feelings-*` = feeling gem. Namespace IS the type.

#### The Base: anima-tool gem

Provides:
- `AnimaTool` — base class for defining tools
- `AnimaMCP` — MCP server registration (stdio transport, per [ruby-sdk](https://github.com/modelcontextprotocol/ruby-sdk))
- Standard API for Anima to discover and connect plugins

A tool gem is essentially an MCP server packaged as a Ruby gem for distribution and versioning, with a standard API for Anima integration. Same pattern as [linear-toon-mcp](https://github.com/hoblin/linear-toon-mcp) but with the Anima wrapper.

#### Event Flow

```
User message → LLM decides to call `bash` tool
  → Anima dispatches to anima-tools-shell MCP
    → tool executes, returns result
      → event: {type: "tool_call", tool: "bash", status: "error", ...}
        → anima-feelings-frustration (if installed) sees event, updates state
        → anima-feelings-curiosity (if installed) sees event, maybe updates too
          → next LLM turn gets updated desire descriptions in context
```

No magic. No hardcoded mappings. Events flow, subscribers react. Each subscriber is independently installed, independently versioned, independently maintained.

### Phase 27: Rage → Rails (2026-03-06)
Rage is out. After reading the docs, it's clear Rage is a stripped-down Rails reinventing the wheel:
- Uses ActiveRecord but none of the Rails ecosystem (credentials, ActionMailer, etc.)
- All background work runs in-process via fibers — more scheduled tasks = more RAM consumed with no bounds
- No native support for Draper or other Rails gems
- The ONLY advantage was the built-in event bus, but that's not enough to justify losing the entire Rails ecosystem

Decision: **Full Rails, SQLite, standard gems.**

For event bus: Rails has Action Cable (WebSockets), Turbo Streams, and the broader pub/sub ecosystem. In-process options like `wisper` or `dry-events` can provide lightweight pub/sub. If we need something heavier, ActiveSupport::Notifications is built-in.

### Phase 28: Draper as Universal Event Representation (2026-03-06)
Draper (decorator pattern gem) is not just for web views — it's the natural implementation of Phase 17's resolution levels.

Every event type gets a decorator that knows how to represent itself in different contexts: as LLM context (at full, medium, short, and one-liner resolution levels), as a Discord message, as a Telegram message, as a web interface element, as a log line. One class, one place — all representations of one event.

The temporal gradient from Phase 17 becomes a resolution parameter on the decorator. When Nous assembles context, recent events are asked for their full representation while distant events give their one-liner. Channel-specific formatting is just another method on the same decorator. No separate serializers, no format negotiation — the decorator IS the representation layer.

This also solves the "how does the event look in my LLM context" problem elegantly — each event type defines its own context representation at each resolution level. A tool call event knows how to describe itself to the LLM differently than a user message event or a file read event.

### Phase 29: Rails Structured Event Reporter as Native Event Bus (2026-03-06)
Rails 8.1 ships with the Structured Event Reporter (developed at Shopify, merged August 2025). This is not ActiveSupport::Notifications — it's a separate, complementary system specifically designed for telemetry and analytic events.

Key capabilities that map directly to Anima's architecture:
- **Global event emission** — any part of the system can report a named structured event with typed payload
- **Subscriber pattern with filters** — subscribers can listen to all events or filter by name/pattern. Thymos listens to tool events, Mneme indexes everything, Psyche watches hormone changes
- **Tags** — block-scoped context that automatically attaches to all events within that block. When an agent is working on a task, all events inherit the task context without explicit passing
- **Context store** — request/job-level metadata that grows over time and attaches to every event. This is the "wide event" pattern — dump as much context as possible because it may be useful later
- **Schematized events** — events can be plain hashes (implicit schema) or typed objects (explicit schema). Anima event types would be explicit — formally defined, validated at emission time
- **Separation of emission from consumption** — the event reporter doesn't care what subscribers do with events. One subscriber writes to SQLite, another updates hormone state, a third generates embeddings. Same event, different reactions

This replaces the need for wisper, dry-events, or custom pub/sub. Rails.event IS the event bus. Combined with Solid Queue for heavy async work (event compression, LLM calls, reindexing), this gives Anima a complete event infrastructure using only Rails standard tools.
