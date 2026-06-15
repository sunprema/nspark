# UX Design Specification: Newtonian Spark

## 1. Design Philosophy

### Core Principle

AI behavior should be treated like software architecture.

Newtonian Spark transforms prompts, rules, skills, memory, and output schemas into structured visual systems that can be designed, validated, versioned, and deployed.

### Design Goals

- Make complex agent logic understandable at a glance.
- Expose dependencies and execution order visually.
- Provide immediate feedback between architecture and compiled output.
- Enable both technical and non-technical stakeholders to collaborate on agent behavior.
- Feel like an engineering tool, not a chat application.

---

# 2. Aesthetic Identity

## Style

**Technical Blueprint**

The interface should feel like an engineering drawing or system architecture document.

Visual references:

- CAD software
- Technical schematics
- Blueprint diagrams
- Infrastructure dashboards

Not:

- Consumer productivity apps
- Generic AI chat interfaces
- Workflow automation tools

---

## Color System

Five muted "ink" colors at equal chroma.

| Type        | Color  |
| ----------- | ------ |
| Persona     | Blue   |
| Constraint  | Red    |
| Context     | Green  |
| Conditional | Gold   |
| Output      | Purple |

Neutral paper and graphite tones for all supporting UI.

---

## Typography

### UI

IBM Plex Sans

### Structural Elements

IBM Plex Mono

Used for:

- Variables
- Node labels
- Compile order
- Diagnostics
- Generated output
- Ports and IDs

---

# 3. Application Layout

## Three-Column Architecture

```text
Resource Rail
     │
     │
Canvas Workspace
     │
     │
Inspector + Compiler
```

The graph remains the primary artifact.

The compiler remains visible at all times.

---

# 4. Left Rail (Resource Navigator)

## Purpose

Navigation, discovery, reuse, and dependency exploration.

---

## 4.1 Node Library

Draggable node types:

- Persona
- Constraint
- Context
- Conditional
- Skill
- Memory
- Tool
- Evaluation
- Output

---

## 4.2 Variable Explorer

Automatically populated from graph analysis.

Example:

```text
{inventory}
{episodic_memory}
{customer_profile}
```

### Interaction

Selecting a variable:

- Highlights all consuming nodes
- Highlights all producing nodes
- Displays dependency path

---

## 4.3 Knowledge Registry

Central repository for reusable assets.

Categories:

### Skills

Reusable capabilities.

Examples:

- Planning
- Retrieval
- Verification
- Compliance

### Policies

Organization-wide rules.

Examples:

- Safety
- Privacy
- Tone

### Schemas

Reusable output formats.

### Memory Templates

Reusable memory structures.

---

## 4.4 Search & Navigation

Global search across:

- Nodes
- Variables
- Skills
- Policies
- Graphs

Results automatically focus the canvas.

---

# 5. Center Workspace (Architecture Canvas)

## Engine

Svelte Flow

---

## Canvas Features

### Infinite Workspace

- Pan
- Zoom
- Multi-select
- Group selection

---

### Smart Navigation

Double-click node:

- Zoom to node
- Open inspector
- Highlight dependencies

---

### Minimap

Persistent overview for large graphs.

---

# 6. Node System

## Node Design

Style C — Left Rail

Features:

- Colored spine
- Neutral body
- Monospace title
- Compact metadata

The graph should remain readable at scale.

---

## Node States

### Active

- Bold outline
- Focus ring

### Muted

- Reduced opacity
- Excluded from compilation
- Struck-through in compiler

### Warning

- Amber indicator
- Validation issue detected

### Error

- Red border
- Compile-blocking issue

Examples:

- Floating node
- Undefined variable
- Invalid schema

---

## Connections

Connections represent:

- Dependency relationships
- Compilation order

Arrow direction determines assembly order.

```text
Persona
  ↓
Constraints
  ↓
Context
  ↓
Output
```

---

# 7. Inspector & Compiler

## Split Inspector Layout

Always visible.

No tab switching required.

---

## Top Panel — Node Inspector

Displays selected node metadata.

### Editable Fields

- Name
- Type
- Description
- Content
- Tags

### Markdown Editor

Full instruction editing.

### Variable Panel

Lists all variables used by the node.

### Compile Controls

- Include in compile
- Mute
- Convert to Skill
- Clone
- Link to Registry

---

## Bottom Panel — Live Compiler

Real-time compiled output.

Read-only.

Updates instantly as the graph changes.

---

## Compiler Information

Displays:

- Token count
- Estimated cost
- Compression percentage
- Compile duration

Example:

```text
2,431 tokens

14% shorter than source

Ready for deployment
```

---

# 8. Compiler Pipeline Visualization

Visible above the compiler.

Shows exact assembly order.

```text
SYSTEM
↓
CONSTRAINTS
↓
CONTEXT
↓
SKILLS
↓
CONDITIONALS
↓
EVALUATIONS
↓
OUTPUT
```

Users should always understand how the final prompt is constructed.

---

# 9. Graph Diagnostics

Persistent validation panel.

Acts as the compiler warning system.

---

## Validation Checks

### Graph Integrity

- Circular dependency detection
- Floating nodes
- Missing connections

### Variables

- Undefined variables
- Unused variables

### Output

- Missing schema
- Invalid schema

### Compilation

- Conflicting instructions
- Duplicate logic

---

## Status States

```text
✓ Ready

⚠ Warning

✕ Error
```

---

# 10. AI Architect

## Purpose

Natural-language copilot for graph design.

The AI modifies architecture directly.

Not merely text.

---

## Example Commands

### Generate

"Create a planning skill."

### Refactor

"Convert repeated logic into a reusable skill."

### Optimize

"Reduce prompt size by 20%."

### Search

"Find inventory-related logic."

### Explain

"Why is this variable required?"

---

## Import & Architect

High-visibility action in the header.

Formerly "Magic Split."

---

### Workflow

1. Paste legacy prompt
2. AI analyzes structure
3. Variables extracted
4. Skills identified
5. Graph generated
6. Diagnostics applied

Result:

```text
Prompt
    ↓
Architecture
```

---

# 11. Versioning & Environments

## Version Graph

Every graph maintains history.

Example:

```text
Version 18
Published

Version 19
Draft
```

---

## Environments

- Development
- Staging
- Production

Deployments are environment-specific.

---

## Diff Viewer

Compare graph versions visually.

Highlight:

- Node additions
- Node removals
- Variable changes
- Compiler output changes

---

# 12. Reusable Packages

Packages are collections of architecture assets.

Example:

```text
Research Agent

├ Persona
├ Constraints
├ Skills
├ Memory
├ Output
```

Packages can be shared and reused across projects.

---

# 13. Core User Flows

## Flow 1 — Prompt to Architecture

1. Import legacy prompt
2. AI Architect analyzes content
3. Graph generated
4. Variables detected
5. Skills suggested

Outcome:

Unstructured text becomes maintainable architecture.

---

## Flow 2 — Equip a Skill

1. Open Knowledge Registry
2. Drag skill onto canvas
3. Linked Skill node created
4. Compiler updates automatically

Outcome:

Reusable behavior added instantly.

---

## Flow 3 — Variable Analysis

1. Click variable
2. Highlight all dependencies
3. Show usage graph

Outcome:

Understand impact before editing.

---

## Flow 4 — Deployment

1. Validate graph
2. Resolve warnings
3. Publish version
4. Deploy to environment

Outcome:

Agent logic becomes production-ready.

---

# 14. UX Success Metrics

## Architecture Clarity

Time required to understand an unfamiliar agent.

---

## Maintenance Speed

Time required to modify behavior safely.

---

## Skill Reuse

Percentage of logic reused across projects.

---

## Deployment Velocity

Time from architecture design to production deployment.

---

## Reliability

Reduction in prompt regressions and output-format failures.
