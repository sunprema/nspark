defmodule Nspark.Registry do
  @moduledoc """
  The Knowledge Registry: reusable assets (skills, policies, schemas, memory
  templates) and packages that bundle them. See docs/HLD.md §4 and UX §4.3.

  Nodes reference registry assets via `Node.source_asset_id` — a "linked" node
  tracks the asset (updates propagate); a "cloned" node copies content and
  detaches. That distinction lives on the Node, not here.
  """
  use Ash.Domain, otp_app: :nspark, extensions: [AshAdmin.Domain, AshPaperTrail.Domain]

  require Ash.Query

  admin do
    show? true
  end

  paper_trail do
    include_versions? true
  end

  resources do
    resource Nspark.Registry.Skill
    resource Nspark.Registry.Policy
    resource Nspark.Registry.Schema
    resource Nspark.Registry.MemoryTemplate
    resource Nspark.Registry.Package
    resource Nspark.Registry.PackageItem
  end

  # ── Skill resolution (Knowledge Layer, plan Phase 2) ─────────────────────────
  #
  # Linked Skill nodes carry a `source_asset_id` instead of owning content. The
  # compiler is pure and never loads from the Registry, so callers resolve the
  # graph against the Registry first, then compile the resolved nodes. This keeps
  # the Skill the single source of truth: edit it once, every linked graph sees
  # the change on its next compile.

  @doc """
  Resolve linked Skill nodes against the Registry.

  For every node of type `:skill` carrying a `source_asset_id`, the node's
  `content` is replaced with the referenced Skill's current content (the latest
  active version — V1 stores a single row per Skill). All other nodes pass
  through unchanged.

  Accepts Ash `Node` structs (live editing) or string-keyed maps (snapshot
  replay). `opts` must carry `:tenant`/`:actor` for loading Skills.

  Returns a map:

    * `:nodes` — the input list with linked Skill content resolved in place
    * `:manifest` — `[%{id, name, version}]`, one per distinct resolved Skill,
      for surfacing resolved versions in compiler output and deployment snapshots
    * `:problems` — `[%{node_id, source_asset_id, reason}]` where `reason` is
      `:missing` or `:deprecated`; empty when everything resolved
  """
  @spec resolve_skills([map()], keyword()) :: %{
          nodes: [map()],
          manifest: [%{id: term(), name: String.t(), version: integer()}],
          problems: [%{node_id: term(), source_asset_id: term(), reason: :missing | :deprecated}]
        }
  def resolve_skills(nodes, opts \\ []) do
    linked = Enum.filter(nodes, &linked_skill?/1)

    if linked == [] do
      %{nodes: nodes, manifest: [], problems: []}
    else
      ids = linked |> Enum.map(&node_source_asset_id/1) |> Enum.uniq()

      skills =
        Nspark.Registry.Skill
        |> Ash.Query.filter(id in ^ids)
        |> Ash.read!(opts)
        |> Map.new(&{&1.id, &1})

      problems =
        Enum.flat_map(linked, fn n ->
          case skill_problem(Map.get(skills, node_source_asset_id(n)), n) do
            nil -> []
            problem -> [problem]
          end
        end)

      resolved_nodes =
        Enum.map(nodes, fn n ->
          case linked_skill?(n) && Map.get(skills, node_source_asset_id(n)) do
            %{status: status} = skill when status != :deprecated ->
              put_content(n, skill.content || "")

            _ ->
              n
          end
        end)

      manifest =
        skills
        |> Map.values()
        |> Enum.reject(&(&1.status == :deprecated))
        |> Enum.map(&%{id: &1.id, name: &1.name, version: &1.version})
        |> Enum.sort_by(& &1.name)

      %{nodes: resolved_nodes, manifest: manifest, problems: problems}
    end
  end

  @doc """
  Convert `resolve_skills/2` problems into `Nspark.Diagnostics`-shaped error maps
  so unresolved references surface in the existing diagnostics panel.
  """
  @spec resolution_diagnostics([map()]) :: [map()]
  def resolution_diagnostics(problems) do
    Enum.map(problems, fn %{node_id: id, reason: reason} ->
      %{level: :error, code: :unresolved_skill, message: unresolved_message(reason), node_ids: [id]}
    end)
  end

  defp unresolved_message(:missing),
    do: "Linked Skill not found — the source asset was deleted or is unavailable."

  defp unresolved_message(:deprecated),
    do: "Linked Skill is deprecated — link a current Skill or restore it."

  defp skill_problem(nil, n),
    do: %{node_id: node_id(n), source_asset_id: node_source_asset_id(n), reason: :missing}

  defp skill_problem(%{status: :deprecated} = skill, n),
    do: %{node_id: node_id(n), source_asset_id: skill.id, reason: :deprecated}

  defp skill_problem(_skill, _n), do: nil

  # ── Skill usage / dependency awareness (Knowledge Layer, plan Phase 3) ───────
  #
  # Before editing shared logic a user must see its blast radius. Usage spans
  # three surfaces: linked Nodes in live graphs, the distinct graphs that consume
  # them, and the deployments whose frozen GraphVersion snapshots embed the Skill.

  @type usage :: %{
          nodes: non_neg_integer(),
          graphs: [%{id: term(), name: String.t()}],
          deployments: [%{id: term(), environment: atom()}]
        }

  @doc """
  Build a `%{skill_id => usage}` map for every Skill referenced anywhere in the
  tenant. Skills with no references are absent from the map (callers default to
  empty usage). `opts` must carry `:tenant`/`:actor`.
  """
  @spec skill_usage_index(keyword()) :: %{term() => usage()}
  def skill_usage_index(opts) do
    linked_nodes =
      Nspark.Architecture.Node
      |> Ash.Query.filter(not is_nil(source_asset_id))
      |> Ash.read!(opts)

    by_skill = Enum.group_by(linked_nodes, & &1.source_asset_id)

    graph_names =
      linked_nodes
      |> Enum.map(& &1.graph_id)
      |> Enum.uniq()
      |> case do
        [] ->
          %{}

        ids ->
          Nspark.Architecture.Graph
          |> Ash.Query.filter(id in ^ids)
          |> Ash.read!(opts)
          |> Map.new(&{&1.id, &1.name})
      end

    deploy_index = deployment_skill_index(opts)

    (Map.keys(by_skill) ++ Map.keys(deploy_index))
    |> Enum.uniq()
    |> Map.new(fn sid ->
      nodes = Map.get(by_skill, sid, [])

      graphs =
        nodes
        |> Enum.map(& &1.graph_id)
        |> Enum.uniq()
        |> Enum.map(&%{id: &1, name: Map.get(graph_names, &1, "(unknown graph)")})
        |> Enum.sort_by(& &1.name)

      {sid, %{nodes: length(nodes), graphs: graphs, deployments: Map.get(deploy_index, sid, [])}}
    end)
  end

  @doc "Usage for a single Skill (empty usage when it is referenced nowhere)."
  @spec skill_usage(term(), keyword()) :: usage()
  def skill_usage(skill_id, opts) do
    opts
    |> skill_usage_index()
    |> Map.get(skill_id, %{nodes: 0, graphs: [], deployments: []})
  end

  # Map each Skill id embedded in an active deployment's frozen snapshot to the
  # deployments that pin it.
  defp deployment_skill_index(opts) do
    Nspark.Deployments.Deployment
    |> Ash.Query.filter(status == :active)
    |> Ash.Query.load(:graph_version)
    |> Ash.read!(opts)
    |> Enum.reduce(%{}, fn dep, acc ->
      snapshot = (dep.graph_version && dep.graph_version.graph_snapshot) || %{}
      entry = %{id: dep.id, environment: dep.environment}

      snapshot
      |> Map.get("nodes", [])
      |> Enum.map(&Map.get(&1, "source_asset_id"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reduce(acc, fn sid, a -> Map.update(a, sid, [entry], &[entry | &1]) end)
    end)
  end

  # ── Duplicate detection / refactor suggestions (Knowledge Layer, plan Phase 5) ─
  #
  # The original goal — "eliminate copy-pasted logic across graphs" — is best
  # served deterministically: find local (non-linked) Skill nodes that share the
  # same content and offer to hoist them into one shared Skill. Reliable and cheap,
  # no model call required.

  @type duplicate_group :: %{
          signature: String.t(),
          content: String.t(),
          label: String.t(),
          count: pos_integer(),
          graphs: [%{id: term(), name: String.t()}],
          node_ids: [term()]
        }

  @doc """
  Find groups of local (non-linked) Skill nodes across the tenant that share the
  same normalized content — copy-pasted logic ripe for extraction into a shared
  Skill. Sorted by occurrence count (descending).

  Only content of at least `min_length` characters appearing in at least
  `min_occurrences` nodes is reported. `opts` must carry `:tenant`/`:actor`.
  """
  @spec duplicate_skill_candidates(keyword(), pos_integer(), pos_integer()) :: [duplicate_group()]
  def duplicate_skill_candidates(opts, min_occurrences \\ 2, min_length \\ 24) do
    nodes =
      Nspark.Architecture.Node
      |> Ash.Query.filter(type == :skill and is_nil(source_asset_id))
      |> Ash.read!(opts)

    grouped =
      nodes
      |> Enum.group_by(&normalize_content(&1.content))
      |> Enum.filter(fn {sig, group} ->
        is_binary(sig) and String.length(sig) >= min_length and length(group) >= min_occurrences
      end)

    if grouped == [] do
      []
    else
      graph_names = graph_name_map(grouped, opts)

      grouped
      |> Enum.map(fn {sig, group} ->
        representative = hd(group)

        graphs =
          group
          |> Enum.map(& &1.graph_id)
          |> Enum.uniq()
          |> Enum.map(&%{id: &1, name: Map.get(graph_names, &1, "(unknown graph)")})
          |> Enum.sort_by(& &1.name)

        %{
          signature: sig,
          content: representative.content,
          label: representative.label,
          count: length(group),
          graphs: graphs,
          node_ids: Enum.map(group, & &1.id)
        }
      end)
      |> Enum.sort_by(& &1.count, :desc)
    end
  end

  defp normalize_content(nil), do: nil

  defp normalize_content(content) do
    case content |> String.trim() |> String.downcase() |> String.replace(~r/\s+/, " ") do
      "" -> nil
      normalized -> normalized
    end
  end

  defp graph_name_map(grouped, opts) do
    ids =
      grouped
      |> Enum.flat_map(fn {_sig, group} -> Enum.map(group, & &1.graph_id) end)
      |> Enum.uniq()

    Nspark.Architecture.Graph
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(opts)
    |> Map.new(&{&1.id, &1.name})
  end

  # ── node accessors (Ash structs and string-keyed snapshot maps) ──────────────

  defp linked_skill?(n), do: node_type(n) == :skill and not is_nil(node_source_asset_id(n))

  defp node_type(%{type: t}), do: t
  defp node_type(%{"type" => "skill"}), do: :skill
  defp node_type(%{"type" => t}) when is_atom(t), do: t
  defp node_type(_), do: nil

  defp node_source_asset_id(%{source_asset_id: id}), do: id
  defp node_source_asset_id(%{"source_asset_id" => id}), do: id
  defp node_source_asset_id(_), do: nil

  defp node_id(%{id: id}), do: id
  defp node_id(%{"id" => id}), do: id
  defp node_id(_), do: nil

  defp put_content(%{"id" => _} = n, content), do: Map.put(n, "content", content)
  defp put_content(n, content), do: Map.put(n, :content, content)
end
