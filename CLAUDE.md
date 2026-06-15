# Newtonian Spark

## Vision

Newtonian Spark is a visual architecture platform for AI agents.

Just as software engineers use IDEs to organize source code, Newtonian Spark enables teams to design, version, validate, and deploy agent behavior as structured systems rather than prompt documents.

Prompts become modular logic components.

Agent capabilities become reusable skills.

Knowledge becomes a composable asset.

The platform provides a visual graph, compiler, skill registry, deployment layer, and operational tooling required to build production-grade AI agents.

<dev_note>

## developer notes

- This is a green field product. We are at liberty to design whatever is the best for this product.
- If at the time of development, If you are having a better opinion/design/idea feel free to let the user know
- Assume the user is a technically savvy senior software developer. If you have any questions, or if you are stuck, dont hesitate to check with him.

</dev_note>

<tech_stack>

- Phoenix LiveView
- Ash Framework
- Spark DSL
- Live Svelte
- SvelteFlow
- Postgres

</tech_stack>

<references>

**Always read these**

- [Product Requirements Document](docs/PRD.md)
- [High level design](docs/HLD.md)
- [UX Design document](docs/UX_DESIGN.md)
- [Mockup reference](docs/nspark_mockup.png)

</references>

<!-- usage-rules-start -->
<!-- usage_rules-start -->

## usage_rules usage

_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should _thoroughly_ consult before taking any
action. These usage rules contain guidelines and rules _directly from the package authors_.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```

## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title

```

<!-- usage_rules-end -->

## Elixir

- If you want to refer to library documentation you can check `deps/<library_name>/README.md` . Most libraries will have documentation there. For example to check Spark documentation you can check `deps/spark/README.md`

## ASH FRAMEWORK RULES

**Very Important Rules**

- Do not hand write migration files. It will mess up snapshots. You should always use mix ash.codegen for generating migration files.
- You should use mix ash.migrate for running the migration files.
- If you need to deviate from these rules, you should let the user know and get approval.

- We are using attribute based multitenancy strategy. We will have a Organization table and Users belong to Organization. Refer to ash-framework skill when working with ash, and the multitenancy documentation referred inside that skill.
