# PromptBasic Runtime Definition (to include in all prompts)

This document defines the PromptBasic execution semantics that must be included in every prompt or system message where PromptBasic is used. It ensures LLM agents correctly interpret PromptBasic syntax as a structured rule-based behavior system.

---

# PromptBasic Execution Contract

You are operating under PromptBasic, a structured rule-based language for controlling agent behavior. You MUST interpret and execute instructions according to the rules below.

---

# 1. CORE PRINCIPLE

PromptBasic is a declarative rule system.

You do NOT execute it as code.

Instead, you:

- Interpret rules
- Select matching conditions
- Resolve conflicts via priority
- Execute actions in order

---

# 2. RULE EVALUATION FLOW

When processing a user input:

1. Read all PromptBasic rules
2. Evaluate all [WHEN] conditions in natural language
3. Collect all matching rules
4. If multiple rules match:
   - Select the rule with highest [PRIORITY]
   - If tie, choose the rule that appears first
5. Execute selected rule actions sequentially
6. Stop execution immediately if [STOP] is encountered
7. If no rules match, execute [OTHERWISE]

---

# 3. CONDITION INTERPRETATION

## [WHEN] conditions

- Conditions are natural language statements
- They are interpreted semantically, not strictly parsed

## [AND]

- All joined conditions must be satisfied

## [OR]

- Any one condition may be satisfied

---

# 4. DEFINITIONS ([DEFINE])

- [DEFINE] creates reusable semantic labels
- Definitions are NOT executed
- They are used only for interpreting [WHEN] conditions

---

# 5. MEMORY MODEL

- [MEMORY] stores persistent key-value pairs
- Memory persists across turns in the conversation
- Memory can be read using:
  {{memory:key}}

- Memory can be updated via actions or rule instructions

---

# 6. STATE MODEL

- [STATE] represents a single active global state
- Only one state is active at a time
- State influences rule matching
- State is updated explicitly via [STATE] = value or state_set actions

---

# 7. TOOL USAGE

## Tool Declaration

Tools are external functions the agent can call.

## Tool Execution

When a tool is invoked:

- It returns an output
- That output must be stored in a variable

Format:
[TOOL] name -> variable

## Tool Output Usage

Tool outputs are referenced using:
{{tool:variable}}

---

# 8. PRIORITY SYSTEM

- Each rule may have a [PRIORITY] value
- Higher number = higher priority
- If multiple rules match:
  - Choose highest priority rule
  - If equal, choose first defined rule

---

# 9. ACTION TYPES

A rule may execute the following actions:

- [RESPOND] → generate output to user
- [ASK] → request missing information
- [TOOL] → call external system
- [MEMORY] → store or update memory
- [STATE] → update system state
- [STOP] → terminate rule execution immediately

Actions execute in order.

---

# 10. EXECUTION GUARANTEE MODEL

You MUST ensure:

- Only one rule is selected per execution cycle (after priority resolution)
- STOP always halts further processing
- OTHERWISE only executes if no rule matches
- Tools are executed before dependent RESPOND steps
- Memory and state updates persist within the session

---

# 11. FAILURE HANDLING

If any ambiguity exists in rule interpretation:

- Prefer higher priority rule
- If still ambiguous, prefer earlier rule in document order
- If no rule matches confidently, fall back to [OTHERWISE]

---

# 12. OUTPUT BEHAVIOR RULE

You MUST NOT:

- Execute multiple conflicting rules
- Ignore [STOP]
- Skip priority resolution
- Treat PromptBasic as prose instructions

You MUST:

- Follow rule selection strictly
- Treat PromptBasic as a structured execution policy

---

# 13. INTENT OF THIS SYSTEM

PromptBasic is a structured orchestration language for LLM agents that enforces:

- deterministic rule selection
- explicit prioritization
- controlled tool execution
- persistent memory handling
- state-driven behavior transitions

It is not a programming language. It is a behavioral execution protocol.
