defmodule Nspark.Orchestrator do
  @moduledoc """
  Executes multi-agent composition for a compiled artifact.

  Parses [AGENT: ...] directives, groups them into dependency waves, dispatches
  each wave in parallel (Phase 2), injects outputs into the variable context,
  then renders the final prompt with all placeholders resolved.

  The parent LLM never sees the directive blocks — the orchestrator strips
  them after dispatch and replaces {output_var} placeholders with the actual
  sub-agent output.

  Orchestration is one level deep: a dispatched sub-agent whose own graph
  contains agent nodes is rejected with an explicit error rather than having its
  raw `[AGENT: ...]` directives leak into the parent output. Recursive
  orchestration is Phase 3 (parked) — see MULTI_AGENT.md.

  See MULTI_AGENT.md for the full design and phased roadmap.
  """

  alias Nspark.Deployments.Deployment
  alias Nspark.Architecture.GraphVersion

  @default_timeout_ms 10_000

  @type directive :: %{
          output_var: String.t(),
          label: String.t(),
          deployment_id: String.t() | nil,
          inputs: %{String.t() => String.t()},
          on_error: String.t(),
          timeout_ms: pos_integer(),
          when_expr: String.t() | nil
        }

  @type sub_agent_call :: %{
          node: String.t(),
          status: :ok | :error | :skipped,
          error: String.t() | nil,
          duration_ms: non_neg_integer()
        }

  @type result :: %{
          prompt: String.t(),
          sub_agent_calls: [sub_agent_call()]
        }

  # Optional `when:` line before [/AGENT] captures conditional routing expressions.
  @directive_re ~r/\[AGENT: ([^\]]+)\]\ncall: (.+?) \(deployment: ([^\)]+)\)\ninputs:\n([\s\S]*?)\noutput: \{[^\}]+\}\non_error: (\w+)\ntimeout: (\d+)(?:\nwhen: ([^\n]+))?\n\[\/AGENT\]/

  @doc """
  Orchestrate a compiled artifact:
  1. Parse [AGENT: ...] directives.
  2. Group into dependency waves; dispatch each wave in parallel.
  3. Strip directive blocks and render the prompt with resolved variables.

  Options:
  - `:tenant` — org_id for Ash multitenancy
  - `:timeout_ms` — global default timeout per sub-agent call (default: #{@default_timeout_ms}ms)

  `variables` is the caller-provided runtime context (string-keyed map).
  """
  @spec run(String.t(), map(), keyword()) :: {:ok, result()} | {:error, map()}
  def run(compiled_text, variables \\ %{}, opts \\ []) do
    {directives, template} = parse(compiled_text)
    waves = group_into_waves(directives)

    case dispatch_waves(waves, variables, opts) do
      {:ok, final_vars, calls} ->
        {:ok, %{prompt: render(template, final_vars), sub_agent_calls: calls}}

      {:error, reason, calls} ->
        {:error, %{reason: reason, sub_agent_calls: calls}}
    end
  end

  @doc """
  Parse a compiled artifact into directives and a stripped prompt template.

  Directive blocks and the ORCHESTRATION section heading are removed from
  the template; `{output_var}` placeholders remain for later rendering.
  """
  @spec parse(String.t()) :: {[directive()], String.t()}
  def parse(compiled_text) do
    directives =
      Regex.scan(@directive_re, compiled_text, capture: :all)
      |> Enum.map(fn captures ->
        # The trailing `when:` group is optional, so `Regex.scan` yields 7 captures
        # (no condition) or 8 (with one). Match the fixed head and treat the rest
        # as the optional when-expression.
        [_full, output_var, label, dep_part, inputs_text, on_error, timeout_str | rest] = captures
        when_str = List.first(rest) || ""

        %{
          output_var: output_var,
          label: label,
          deployment_id: if(dep_part == "latest", do: nil, else: dep_part),
          inputs: parse_inputs(inputs_text),
          on_error: on_error,
          timeout_ms: String.to_integer(timeout_str),
          when_expr: if(when_str == "", do: nil, else: when_str)
        }
      end)

    template =
      compiled_text
      |> String.replace(~r/# ORCHESTRATION\n\n/, "")
      |> String.replace(@directive_re, "")
      |> String.trim()

    {directives, template}
  end

  @doc """
  Render a prompt template by substituting `{variable}` placeholders.
  Unresolved placeholders are left as-is.
  """
  @spec render(String.t(), map()) :: String.t()
  def render(template, variables) do
    Regex.replace(~r/\{([a-zA-Z_]\w*)\}/, template, fn _, name ->
      case Map.get(variables, name) do
        nil -> "{#{name}}"
        v when is_binary(v) -> v
        v -> inspect(v)
      end
    end)
  end

  @doc """
  Group directives into waves for parallel dispatch.

  Directives whose inputs don't depend on any other directive's output_var are
  in wave 0 and run in parallel. Directives that consume wave-0 outputs are in
  wave 1, and so on. Within a wave, all directives run concurrently.

  Conditional `when:` expressions that reference another directive's output_var
  are treated as implicit dependencies — the condition can't be evaluated until
  the referenced agent has run and injected its output into the variable context.
  """
  @spec group_into_waves([directive()]) :: [[directive()]]
  def group_into_waves([]), do: []
  def group_into_waves(directives) do
    indexed = Enum.with_index(directives)
    output_to_idx = Map.new(indexed, fn {d, i} -> {d.output_var, i} end)

    dep_map =
      Map.new(indexed, fn {d, i} ->
        input_vars = Map.values(d.inputs)
        when_vars = extract_when_vars(d[:when_expr])

        deps =
          (input_vars ++ when_vars)
          |> Enum.flat_map(fn var_ref ->
            case Map.get(output_to_idx, var_ref) do
              nil -> []
              j -> [j]
            end
          end)

        {i, MapSet.new(deps)}
      end)

    wave_of =
      Enum.reduce(Enum.map(indexed, fn {_, i} -> i end), %{}, fn i, acc ->
        dep_waves =
          dep_map
          |> Map.get(i, MapSet.new())
          |> Enum.map(&Map.get(acc, &1, 0))

        wave = if dep_waves == [], do: 0, else: Enum.max(dep_waves) + 1
        Map.put(acc, i, wave)
      end)

    indexed
    |> Enum.group_by(fn {_, i} -> Map.get(wave_of, i, 0) end, fn {d, _} -> d end)
    |> Enum.sort_by(fn {wave, _} -> wave end)
    |> Enum.map(fn {_, ds} -> ds end)
  end

  # ── wave dispatch ─────────────────────────────────────────────────────────────

  defp dispatch_waves(waves, initial_vars, opts) do
    Enum.reduce_while(waves, {:ok, initial_vars, []}, fn wave, {:ok, vars, calls} ->
      case dispatch_wave(wave, vars, opts) do
        {:ok, new_vars, wave_calls} ->
          {:cont, {:ok, new_vars, calls ++ wave_calls}}

        {:error, reason, wave_calls} ->
          {:halt, {:error, reason, calls ++ wave_calls}}
      end
    end)
    |> then(fn
      {:ok, vars, calls} -> {:ok, vars, calls}
      {:error, reason, calls} -> {:error, reason, calls}
    end)
  end

  defp dispatch_wave(directives, vars, opts) do
    global_timeout = opts[:timeout_ms] || @default_timeout_ms

    # Evaluate conditional routing: skip directives whose when_expr is false.
    {active, skipped} = Enum.split_with(directives, fn d ->
      evaluate_condition(d[:when_expr], vars)
    end)

    skipped_calls =
      Enum.map(skipped, fn d ->
        %{node: d.output_var, status: :skipped, error: nil, duration_ms: 0}
      end)

    skipped_vars = Map.new(skipped, fn d -> {d.output_var, nil} end)

    tasks =
      Enum.map(active, fn directive ->
        timeout = directive.timeout_ms || global_timeout
        task = Task.async(fn ->
          t0 = System.monotonic_time(:millisecond)
          result = dispatch_one(directive, vars, opts)
          elapsed = System.monotonic_time(:millisecond) - t0
          {result, elapsed}
        end)
        {directive, task, timeout}
      end)

    results =
      Enum.map(tasks, fn {directive, task, timeout} ->
        outcome =
          try do
            Task.await(task, timeout)
          catch
            :exit, {:timeout, _} ->
              Task.shutdown(task, :brutal_kill)
              {{:error, "timeout after #{timeout}ms"}, timeout}
          end

        {directive, outcome}
      end)

    case process_wave_results(results, Map.merge(vars, skipped_vars)) do
      {:ok, new_vars, active_calls} ->
        {:ok, new_vars, skipped_calls ++ active_calls}

      {:error, reason, active_calls} ->
        {:error, reason, skipped_calls ++ active_calls}
    end
  end

  defp process_wave_results(results, vars) do
    {new_vars, calls, failed} =
      Enum.reduce(results, {vars, [], nil}, fn {directive, {result, elapsed}}, {v, cs, fail} ->
        case result do
          {:ok, output} ->
            call = %{node: directive.output_var, status: :ok, error: nil, duration_ms: elapsed}
            {Map.put(v, directive.output_var, output), cs ++ [call], fail}

          {:error, reason} when directive.on_error == "continue" ->
            call = %{node: directive.output_var, status: :error, error: inspect(reason), duration_ms: elapsed}
            {Map.put(v, directive.output_var, nil), cs ++ [call], fail}

          {:error, reason} ->
            call = %{node: directive.output_var, status: :error, error: inspect(reason), duration_ms: elapsed}
            {v, cs ++ [call], inspect(reason)}
        end
      end)

    if failed do
      {:error, failed, calls}
    else
      {:ok, new_vars, calls}
    end
  end

  # ── single directive dispatch ─────────────────────────────────────────────────

  defp dispatch_one(%{deployment_id: nil, label: label}, _vars, _opts) do
    {:error, "Agent \"#{label}\" has no pinned deployment"}
  end

  defp dispatch_one(%{deployment_id: dep_id, inputs: inputs, label: label}, vars, opts) do
    tenant = opts[:tenant]
    ash_opts = [authorize?: false] ++ if(tenant, do: [tenant: tenant], else: [])

    resolved_inputs =
      Map.new(inputs, fn {param, var_ref} ->
        {param, Map.get(vars, var_ref, "{#{var_ref}}")}
      end)

    with {:ok, dep} <- Ash.get(Deployment, dep_id, ash_opts),
         {:ok, version} <- Ash.get(GraphVersion, dep.graph_version_id, ash_opts) do
      snapshot = version.graph_snapshot || %{}
      nodes = Map.get(snapshot, "nodes", [])
      edges = Map.get(snapshot, "edges", [])
      compiled = Nspark.Compiler.compile(nodes, edges)

      # A sub-agent whose own graph contains (unmuted) agent nodes compiles to an
      # artifact with its own [AGENT: ...] directives. We do not recursively
      # orchestrate (Phase 3, parked), so rendering it as-is would leak raw
      # directive text into the parent prompt as if it were a real result. Fail
      # loudly instead — `on_error` still decides whether that halts the run or
      # degrades this output to nil.
      case parse(compiled.markdown) do
        {[], _template} ->
          {:ok, render(compiled.markdown, resolved_inputs)}

        {[_ | _], _template} ->
          {:error,
           "Agent \"#{label}\" expands to a sub-graph that itself contains agent nodes; " <>
             "nested orchestration is not supported"}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ── condition evaluation ──────────────────────────────────────────────────────

  # Extract the variable name(s) referenced in a when_expr so the wave grouper
  # can treat them as implicit dependencies.
  defp extract_when_vars(nil), do: []
  defp extract_when_vars(""), do: []
  defp extract_when_vars(expr) do
    Regex.scan(~r/\{([a-zA-Z_]\w*)\}/, expr)
    |> Enum.map(fn [_, name] -> name end)
  end

  # No condition → always dispatch.
  defp evaluate_condition(nil, _vars), do: true
  defp evaluate_condition("", _vars), do: true

  defp evaluate_condition(expr, vars) do
    expr = String.trim(expr)

    cond do
      # Negated truthy: !{var}
      String.starts_with?(expr, "!") ->
        var_name = expr |> String.trim_leading("!") |> extract_var_name()
        val = Map.get(vars, var_name)
        val in [nil, "", "false", "0", false]

      # Equality: {var} == "value"
      String.contains?(expr, " == ") ->
        [var_part, val_part] = String.split(expr, " == ", parts: 2)
        var_name = var_part |> String.trim() |> extract_var_name()
        expected = val_part |> String.trim() |> String.trim("\"")
        to_string(Map.get(vars, var_name, "")) == expected

      # Inequality: {var} != "value"
      String.contains?(expr, " != ") ->
        [var_part, val_part] = String.split(expr, " != ", parts: 2)
        var_name = var_part |> String.trim() |> extract_var_name()
        expected = val_part |> String.trim() |> String.trim("\"")
        to_string(Map.get(vars, var_name, "")) != expected

      # Truthy: {var}
      true ->
        var_name = extract_var_name(expr)
        val = Map.get(vars, var_name)
        val not in [nil, "", "false", "0", false]
    end
  end

  defp extract_var_name(s) do
    case Regex.run(~r/^\{([a-zA-Z_]\w*)\}$/, s) do
      [_, name] -> name
      _ -> s
    end
  end

  # ── input mapping parsing ─────────────────────────────────────────────────────

  defp parse_inputs(text) when text in ["  (none)", "(none)"], do: %{}

  defp parse_inputs(text) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s+(\w+): \{(\w+)\}$/, line) do
        [_, param, var_ref] -> [{param, var_ref}]
        _ -> []
      end
    end)
    |> Map.new()
  end
end
