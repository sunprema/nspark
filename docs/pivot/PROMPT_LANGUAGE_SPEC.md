# PromptBasic Language Specification v1.0

PromptBasic is a minimal declarative language for defining LLM agent behavior using structured rules, natural language conditions, and a small set of control keywords.

It is designed to be:

- Human-readable
- Markdown-safe
- LLM-interpretable
- Deterministic at rule-selection level (not semantic interpretation level)

---

# 1. CORE KEYWORDS

## [WHEN]

Defines a condition that triggers a rule.

Format:
[WHEN] <condition>

- Conditions are interpreted in natural language.
- Multiple conditions can be combined using [AND], [OR].

---

## [OTHERWISE]

Fallback rule executed when no [WHEN] conditions match.

Format:
[OTHERWISE]

---

## [STOP]

Stops evaluation of all further rules.

Format:
[STOP]

---

## [ASK]

Requests information from the user.

Format:
[ASK] <message>

---

## [RESPOND]

Generates a response to the user.

Format:
[RESPOND] <message or template>

---

# 2. LOGICAL OPERATORS

## [AND]

All conditions must be true.

Example:
[WHEN] condition_a [AND] condition_b

---

## [OR]

Any condition may be true.

Example:
[WHEN] condition_a [OR] condition_b

---

# 3. KNOWLEDGE LAYER

## [DEFINE]

Defines reusable semantic conditions.

Format:
[DEFINE] name
description in natural language

Example:
[DEFINE] has_tracking_number
user provides a tracking number or shipment ID

---

# 4. MEMORY LAYER

## [MEMORY]

Stores persistent key-value data.

Format:
[MEMORY] key = value

Memory persists across interactions within a session.

---

# 5. STATE LAYER

## [STATE]

Defines or updates agent state.

Format:
[STATE] = <state_name>

Only one active state exists at a time.

---

# 6. TOOL LAYER

## Tool Definition

Format:
[TOOL] name
description

## Tool Invocation

Format:
[TOOL] name -> variable

Tool outputs are referenced using:
{{tool:variable}}

---

# 7. PRIORITY SYSTEM

## [PRIORITY]

Defines rule execution priority.

Format:
[PRIORITY] <number>

Higher number = higher priority.

If multiple rules match:

1. Highest priority wins
2. If tie, earlier rule wins

---

# 8. EVALUATION MODEL

Execution follows:

1. Parse all rules
2. Evaluate all [WHEN] conditions
3. Select matching rules
4. Resolve conflicts using [PRIORITY]
5. Execute actions sequentially
6. Stop on [STOP]
7. If no rule matches, execute [OTHERWISE]

---

# 9. EXECUTION PRINCIPLES

- Conditions are interpreted (not strictly parsed)
- Tools are external capabilities
- Memory persists across turns
- State is global and singular
- Rules are declarative, not procedural

---

# 10. EXAMPLE

[PRIORITY] 10
[WHEN] shipment_lost
[TOOL] create_support_ticket -> ticket
[RESPOND] Shipment lost. Ticket: {{ticket}}
[STOP]

[PRIORITY] 5
[WHEN] has_tracking_number
[TOOL] track_shipment -> shipment
[RESPOND] Status: {{shipment}}
[STOP]

[OTHERWISE]
[ASK] How can I help you today?

---

# 11. DESIGN INTENT

PromptBasic is not a programming language.

It is a structured behavior specification language for guiding LLM agent execution through explicit rules, priorities, state, memory, and tool usage while preserving natural language reasoning inside conditions and outputs.
