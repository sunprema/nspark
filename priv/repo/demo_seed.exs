# Idempotent demo data for the architecture studio.
#
#     mix run priv/repo/demo_seed.exs
#
# Creates (once) a "Nspark Demo" org + project + an "Agent Planner" graph with
# positioned nodes and edges so /studio renders something real.

import Ash.Query, only: [filter: 2]

alias Nspark.Accounts.Organization
alias Nspark.Projects.Project
alias Nspark.Architecture.{Graph, Node, Edge}

org =
  case Organization |> filter(slug == "nspark-demo") |> Ash.read!() do
    [org | _] -> org
    [] -> Ash.create!(Organization, %{name: "Nspark Demo", slug: "nspark-demo"})
  end

t = [tenant: org.id]

existing = Graph |> filter(name == "Agent Planner") |> Ash.read!(t)

graph =
  case existing do
    [g | _] ->
      IO.puts("Demo graph already exists (#{g.id}). Nothing to do.")
      g

    [] ->
      project = Ash.create!(Project, %{name: "Demo Project", status: :active}, t)
      graph = Ash.create!(Graph, %{name: "Agent Planner", project_id: project.id}, t)

      node = fn type, label, content, x, y, muted ->
        Ash.create!(
          Node,
          %{
            type: type,
            label: label,
            content: content,
            is_muted: muted,
            graph_id: graph.id,
            metadata: %{"position" => %{"x" => x, "y" => y}}
          },
          t
        )
      end

      persona =
        node.(
          :persona,
          "Planner Persona",
          "You are a planner within an agent system navigating a text-based game.",
          200,
          20,
          false
        )

      constraint =
        node.(
          :constraint,
          "Sub-goal Logic",
          "Maintain sub-goal wording until completion. Do not alter the plan from {plan0}.",
          200,
          170,
          false
        )

      context =
        node.(
          :context,
          "Memory Logic",
          "Integrate {episodic_memory} and {subgraph} when ranking next steps.",
          200,
          320,
          false
        )

      conditional =
        node.(
          :conditional,
          "Explore Mode",
          "IF {mode} == 'explore': list all {all_unexpl_exits} and add exit instructions.",
          200,
          470,
          false
        )

      inventory =
        node.(
          :constraint,
          "Inventory Check",
          "If task is to obtain an item, verify it is in {inventory} before completion.",
          560,
          320,
          true
        )

      output =
        node.(
          :output,
          "Output Format",
          "Return ONLY JSON: { main_goal, plan_steps[], emotion }",
          200,
          620,
          false
        )

      _ = inventory

      edge = fn src, tgt ->
        Ash.create!(
          Edge,
          %{graph_id: graph.id, source_node_id: src.id, target_node_id: tgt.id},
          t
        )
      end

      edge.(persona, constraint)
      edge.(constraint, context)
      edge.(context, conditional)
      edge.(conditional, output)

      IO.puts("Created demo graph #{graph.id} with 6 nodes / 4 edges.")
      graph
  end

IO.puts("Open /studio  (org=#{org.slug}, graph=#{graph.name})")
