defmodule Nspark.OrchestratorTest do
  use Nspark.DataCase, async: true

  alias Nspark.Accounts.{Membership, Organization}
  alias Nspark.Architecture
  alias Nspark.Architecture.{Graph, Node}
  alias Nspark.Compiler
  alias Nspark.Orchestrator
  alias Nspark.Projects.Project

  # ── pure functions (no DB) ────────────────────────────────────────────────────

  describe "parse/1" do
    test "parses an agent directive with no when: clause (regression)" do
      # The trailing when: group is optional; Regex.scan yields 7 captures here,
      # which previously raised a FunctionClauseError.
      md =
        Compiler.compile(
          [agent_node("inner", "latest")],
          []
        ).markdown

      assert {[directive], _template} = Orchestrator.parse(md)
      assert directive.output_var == "inner"
      assert directive.when_expr == nil
    end

    test "parses an agent directive with a when: clause" do
      nodes = [
        %{"id" => "c", "type" => "conditional", "label" => "C", "content" => "{flag}", "metadata" => %{}},
        agent_node("inner", "latest")
      ]

      edges = [%{"id" => "e", "source_node_id" => "c", "target_node_id" => "ag", "metadata" => %{"branch" => "yes"}}]

      md = Compiler.compile(nodes, edges).markdown
      assert {[directive], _t} = Orchestrator.parse(md)
      assert directive.when_expr == "{flag}"
    end

    test "strips directive blocks from the template but keeps placeholders elsewhere" do
      md = Compiler.compile([persona_map("Result: {inner}"), agent_node("inner", "latest")], []).markdown
      {_directives, template} = Orchestrator.parse(md)

      refute template =~ "[AGENT:"
      assert template =~ "Result: {inner}"
    end
  end

  describe "render/2" do
    test "substitutes known variables and leaves unknown placeholders intact" do
      assert Orchestrator.render("Hi {name}, {missing}", %{"name" => "Ada"}) == "Hi Ada, {missing}"
    end
  end

  describe "group_into_waves/1" do
    test "a directive consuming another's output lands in a later wave" do
      a = %{output_var: "a", inputs: %{}, when_expr: nil}
      b = %{output_var: "b", inputs: %{"x" => "a"}, when_expr: nil}

      assert [[%{output_var: "a"}], [%{output_var: "b"}]] = Orchestrator.group_into_waves([a, b])
    end
  end

  # ── nested sub-agent boundary (one level deep) ────────────────────────────────

  describe "nested sub-agents" do
    setup do
      org = Ash.create!(Organization, %{name: "Orch", slug: "orch-org"})
      user = Ash.Seed.seed!(Nspark.Accounts.User, %{email: "orch@example.com"})
      Ash.create!(Membership, %{user_id: user.id, organization_id: org.id, role: :owner})

      t = [tenant: org.id, authorize?: false]
      project = Ash.create!(Project, %{name: "P", status: :active}, t)
      %{org: org, user: user, t: t, project: project}
    end

    test "a sub-agent whose graph contains agent nodes is rejected, not leaked", ctx do
      # Sub-agent deployment whose own graph nests an agent node.
      dep = deploy_subagent(ctx, [persona("sub persona", ctx), agent_record("inner", ctx)])
      result = Orchestrator.run(parent_artifact(dep.id, "fail"), %{}, tenant: ctx.org.id)

      assert {:error, %{reason: reason, sub_agent_calls: calls}} = result
      assert reason =~ "nested orchestration is not supported"
      # The raw directive never leaks into a rendered prompt.
      refute match?({:ok, _}, result)
      assert Enum.any?(calls, &(&1.status == :error))
    end

    test "with on_error=continue the nested sub-agent degrades to nil instead of leaking", ctx do
      dep = deploy_subagent(ctx, [persona("sub persona", ctx), agent_record("inner", ctx)])
      assert {:ok, %{prompt: prompt, sub_agent_calls: calls}} =
               Orchestrator.run(parent_artifact(dep.id, "continue"), %{}, tenant: ctx.org.id)

      # nil output → the {subresult} placeholder is left unresolved, and crucially
      # no [AGENT: ...] directive text is injected.
      refute prompt =~ "[AGENT:"
      assert Enum.any?(calls, &(&1.status == :error))
    end

    test "a normal (non-nested) sub-agent still resolves and renders", ctx do
      dep = deploy_subagent(ctx, [persona("Hello from the sub-agent", ctx)])
      assert {:ok, %{prompt: prompt, sub_agent_calls: [call]}} =
               Orchestrator.run(parent_artifact(dep.id, "fail"), %{}, tenant: ctx.org.id)

      assert call.status == :ok
      assert prompt =~ "Hello from the sub-agent"
      refute prompt =~ "[AGENT:"
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────────

  # string-keyed snapshot nodes (for in-memory compile)
  defp agent_node(output_var, dep_id),
    do: %{
      "id" => "ag",
      "type" => "agent",
      "label" => "Nested",
      "content" => nil,
      "metadata" => %{"output_var" => output_var, "source_deployment_id" => dep_id}
    }

  defp persona_map(content),
    do: %{"id" => "p", "type" => "persona", "label" => "P", "content" => content, "metadata" => %{}}

  # The parent prompt: a persona referencing {subresult} + an agent directive
  # pointing at a real sub-agent deployment.
  defp parent_artifact(dep_id, on_error) do
    nodes = [
      %{type: :persona, label: "Parent", content: "Summary: {subresult}", metadata: %{}},
      %{
        type: :agent,
        label: "SubCall",
        content: nil,
        metadata: %{"output_var" => "subresult", "source_deployment_id" => dep_id, "on_error" => on_error}
      }
    ]

    Compiler.compile(nodes, []).markdown
  end

  # persisted Ash nodes for a sub-agent graph
  defp persona(content, ctx), do: %{type: :persona, label: "P", content: content, metadata: %{}}
  defp agent_record(output_var, _ctx),
    do: %{type: :agent, label: "Nested", content: nil, metadata: %{"output_var" => output_var}}

  defp deploy_subagent(ctx, node_attrs) do
    graph =
      Ash.create!(Graph, %{name: "SG-#{System.unique_integer([:positive])}", project_id: ctx.project.id}, ctx.t)

    nodes =
      Enum.map(node_attrs, fn attrs ->
        Ash.create!(Node, Map.merge(attrs, %{graph_id: graph.id}), ctx.t)
      end)

    {:ok, version} = Architecture.publish_graph(graph, nodes, [], ctx.user, ctx.org.id, [])

    {:ok, dep} =
      Nspark.Deployments.deploy_version(
        %{
          environment: :production,
          project_id: ctx.project.id,
          graph_version_id: version.id,
          deployed_version: version.version_number
        },
        ctx.t
      )

    dep
  end
end
