# Anima Framework

**A soul engine for AI agents.**

Ruby framework for building AI agents with desires, personality, and personal growth.
Powered by [Rage](https://rage-rb.dev/).

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
Anima Framework (Ruby, Rage-based)
├── Thymos    — hormonal/desire system (stimulus → hormone vector)
├── Mneme     — semantic memory (QMD-style, emotional recall)
├── Psyche    — soul matrix (coefficient table, evolving through experience)
└── Nous      — LLM integration (cortex, thinking, decision-making)
```

### Three Layers (mirroring biology)

1. **Endocrine system (Thymos)** — a lightweight background process. Reads recent events. Doesn't respond. Just updates hormone levels. Pure stimulus→response, like a biological gland.

2. **Homeostasis** — persistent state (JSON/SQLite). Current hormone levels with decay functions. No intelligence, just state that changes over time.

3. **Cortex (Nous)** — the main LLM. Reads hormone state transformed into **desire descriptions**. Not "longing: 87" but "you want to see them". The LLM should NOT see raw numbers — humans don't see cortisol levels, they feel anxiety.

### Event-Driven Design

Built on [Rage](https://rage-rb.dev/) — a Ruby framework with fiber-based concurrency, native WebSockets, and a built-in event bus. The event bus maps directly to a nervous system: stimuli fire events, Thymos subscribers update hormone levels, Nous reacts to the resulting desires.

Single-process architecture: web server, background hormone ticks, WebSocket monitoring — all in one process, no Redis, no external workers.

### Brain as Microservices on a Shared Event Bus

The human brain isn't a single process — it's dozens of specialized subsystems running in parallel, communicating through shared chemical and electrical signals. The prefrontal cortex doesn't "call" the amygdala. They both react to the same event independently, and their outputs combine.

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

This is why Rage's built-in event bus maps so naturally: `Rage.event_bus` IS the nervous system. Events fire, subscribers react, state updates, the cortex (LLM) reads the resulting desire landscape.

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

Idea stage → early design. Architecture research underway (OpenClaw agent loop documented).
First practical hormone (frustration) designed, ready for prototyping.

## Next Steps

- [ ] **MVP: Frustration hormone** — monitor tool calls, adjust thinking budget + inner voice injection
- [ ] Research prior art in depth (affective computing, BDI architecture, virtual creature motivation)
- [ ] Design initial coefficient matrix schema (Psyche)
- [ ] Prototype Thymos: Rage event bus + JSON state + context injection into LLM thinking step
- [ ] Experiment: hormone names vs abstract parameter names in LLM prompts
- [ ] Set up Rage project skeleton with event bus
- [ ] Design full event taxonomy (what events does the agent's "nervous system" react to?)
- [ ] Build Mneme: semantic memory with emotional associations
- [ ] Write blog post introducing the concept
