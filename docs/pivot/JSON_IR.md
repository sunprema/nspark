# JSON_IR.md — PromptBasic Intermediate Representation (IR) Specification v1.0

This document defines the canonical JSON Intermediate Representation (IR) for PromptBasic.

It is intended for implementation agents, runtimes, simulators, and visualizers as the single source of truth for executing PromptBasic programs.

---

# PURPOSE

The JSON IR is the executable representation of PromptBasic.

It exists to:

- Provide a deterministic execution model for PromptBasic rules
- Enable simulation without re-parsing natural language prompts
- Power visualizers (graph, state machine, debugger views)
- Support tool orchestration and memory/state tracking
- Enable static analysis such as conflict detection, unreachable rules, and priority resolution issues

---

# CORE PRINCIPLE

PromptBasic (text format) is human-authored.

JSON IR is machine-executed.

The IR must be:

- Fully structured
- Non-ambiguous
- Execution-ready
- Independent of markdown or prompt formatting

---

# TOP LEVEL STRUCTURE

{
"name": "string",
"version": "1.0",
"memory": {},
"state": {},
"tools": [],
"definitions": [],
"rules": []
}

---

# MEMORY MODEL

Memory is a persistent key-value store.

{
"memory": {
"key": "value"
}
}

Memory rules:

- Mutable across execution cycles
- Shared across all rules
- Used for cross-turn persistence

---

# STATE MODEL

State represents the current execution context.

{
"state": {
"current": "idle",
"valid": ["idle", "active", "error"]
}
}

State rules:

- Only one active state at a time
- Globally accessible
- Explicitly updated via state_set actions

---

# DEFINITIONS

Definitions are semantic predicates derived from PromptBasic [DEFINE].

{
"definitions": [
{
"id": "has_tracking_number",
"expression": "user provides a tracking number or shipment ID"
}
]
}

Definitions rules:

- Used only for condition evaluation
- Not executed directly
- May be interpreted by LLM or classifier layer

---

# TOOLS

Tools represent external capabilities available to the agent.

Tool declaration:

{
"id": "track_shipment",
"description": "Fetch shipment status",
"input": ["tracking_id"],
"output": "shipment_data"
}

Tool rules:

- Tools may be real or mocked
- Execution is external to rule engine

---

Tool invocation inside rules:

{
"type": "tool",
"tool": "track_shipment",
"input": ["tracking_id"],
"output": "shipment"
}

Tool outputs are referenced using:
{{tool:variable}}

---

# RULE STRUCTURE

Each rule is a deterministic execution unit.

{
"id": "rule_id",
"priority": 10,
"when": {},
"actions": []
}

Rule rules:

- Each rule is independent
- Multiple rules may match
- Conflict resolved via priority system

---

# CONDITIONS

Conditions define rule matching logic.

AND condition:
{
"and": ["condition_a", "condition_b"]
}

OR condition:
{
"or": ["condition_a", "condition_b"]
}

Conditions may refer to:

- definitions
- state
- memory
- inferred user intent (via LLM or classifier layer)

---

# PRIORITY SYSTEM

Each rule may define a priority:

"priority": 10

Priority rules:

- Higher number = higher priority
- If multiple rules match:
  - Highest priority wins
  - If tie, first defined rule wins
- If no rule matches, fallback rule executes

---

# ACTION TYPES

Actions execute sequentially.

---

Tool action:
{
"type": "tool",
"tool": "track_shipment",
"input": ["tracking_id"],
"output": "shipment"
}

---

Respond action:
{
"type": "respond",
"template": "Shipment status: {{shipment}}"
}

---

Ask action:
{
"type": "ask",
"message": "Please provide tracking number"
}

---

Memory set action:
{
"type": "memory_set",
"key": "last_tracking_id",
"value": "user.tracking_number"
}

---

State set action:
{
"type": "state_set",
"value": "active_tracking"
}

---

Stop action:
{
"type": "stop"
}

Stop behavior:

- Immediately terminates rule execution
- No further rules or actions are evaluated

---

# RULE EXAMPLE

{
"id": "rule_delayed",
"priority": 8,
"when": {
"and": ["has_tracking_number", "shipment_delayed"]
},
"actions": [
{
"type": "tool",
"tool": "track_shipment",
"output": "shipment"
},
{
"type": "respond",
"template": "Your shipment is delayed: {{shipment}}"
},
{
"type": "stop"
}
]
}

---

# EXECUTION MODEL

The runtime MUST follow this deterministic process:

1. Parse JSON IR
2. Evaluate all rule conditions
3. Collect all matching rules
4. Resolve conflicts using priority
5. Execute selected rule actions sequentially
6. Update memory and state
7. Stop execution if STOP is encountered
8. If no rule matches, execute fallback behavior

---

# TRACE MODEL

Execution steps MUST emit trace events for debugging:

{
"step": 1,
"rule": "rule_delayed",
"action": "tool:track_shipment",
"output": "shipment_data"
}

Trace events must include:

- rule id
- action type
- tool outputs (if any)
- memory/state updates (if any)

---

# VALIDATION RULES

A valid IR must:

- Contain at least one rule
- Define fallback behavior (explicit or implicit)
- Avoid unresolved tool references
- Ensure STOP halts execution deterministically
- Ensure priority conflicts are resolvable

---

# DESIGN INTENT

This IR is not a programming runtime.

It is a deterministic orchestration graph for LLM-driven agents.

It separates:

- Logic (rules and conditions)
- Execution (actions)
- Interpretation (LLM/classifier layer)
- Visualization (graph/state/debug systems)
