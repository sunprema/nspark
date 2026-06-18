defmodule NsparkWeb.OrgUsageLive do
  @moduledoc """
  Runtime usage for the active organization — the read side of the observability
  substrate (`Nspark.Observability.RunEvent`). Shows all-time headline stats and
  the most recent resolution events (prompt fetches and deployment runs).

  Headline stats are computed all-time via SQL count/avg aggregates (no rows
  loaded); the events table shows the recent window the `:recent` read returns.
  """
  use NsparkWeb, :live_view

  on_mount {NsparkWeb.LiveUserAuth, :live_user_and_tenant_required}

  require Ash.Query

  alias Nspark.Observability
  alias Nspark.Observability.RunEvent

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_data(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load_data(socket)}

  # ── data ──────────────────────────────────────────────────────────────────

  defp load_data(socket) do
    org_id = socket.assigns.current_org.id
    actor = socket.assigns.current_user
    opts = [tenant: org_id, actor: actor]

    events =
      Observability.recent_run_events!(nil, opts)
      |> Ash.load!([:graph], opts)

    socket
    |> assign(:events, events)
    |> assign(:stats, all_time_stats(opts))
  end

  # All-time headline stats, computed as SQL aggregates (count/avg) so the whole
  # history is summarized without loading rows. Tenant scoping and the viewer
  # read policy both flow through `opts`.
  defp all_time_stats(opts) do
    case Ash.count!(RunEvent, opts) do
      0 ->
        %{total: 0, ok: 0, errors: 0, success_rate: nil, avg_latency: nil, by_source: %{}}

      total ->
        ok = RunEvent |> Ash.Query.filter(status == :ok) |> Ash.count!(opts)
        fetch = RunEvent |> Ash.Query.filter(source == :prompt_fetch) |> Ash.count!(opts)
        run = RunEvent |> Ash.Query.filter(source == :deployment_run) |> Ash.count!(opts)
        %{avg_latency: avg} = Ash.aggregate!(RunEvent, {:avg_latency, :avg, field: :latency_ms}, opts)

        %{
          total: total,
          ok: ok,
          errors: total - ok,
          success_rate: round(ok / total * 100),
          avg_latency: round_num(avg),
          by_source:
            %{prompt_fetch: fetch, deployment_run: run}
            |> Map.reject(fn {_src, n} -> n == 0 end)
        }
    end
  end

  # Postgres `avg` comes back as a Decimal; normalize either that or a plain
  # number to a rounded integer (and pass nil through when there's no data).
  defp round_num(nil), do: nil
  defp round_num(%Decimal{} = d), do: d |> Decimal.round() |> Decimal.to_integer()
  defp round_num(n) when is_number(n), do: round(n)

  # ── view helpers ────────────────────────────────────────────────────────────

  defp graph_name(%{graph: %{name: name}}), do: name
  defp graph_name(_), do: "—"

  defp source_label(:prompt_fetch), do: "FETCH"
  defp source_label(:deployment_run), do: "RUN"
  defp source_label(other), do: String.upcase(to_string(other))

  defp fmt_num(nil), do: "—"
  defp fmt_num(n), do: Integer.to_string(n)

  defp fmt_time(nil), do: "—"
  defp fmt_time(dt), do: Calendar.strftime(dt, "%b %d, %H:%M:%S")

  # ── render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.workspace flash={@flash}>
      <div class="members-page">
        <div class="members-bar">
          <a href={~p"/studio"} class="studio-btn" style="text-decoration: none;">← Studio</a>
          <div class="members-title">USAGE · {String.upcase(@current_org.name)}</div>
          <button type="button" phx-click="refresh" class="members-action-btn">Refresh</button>
        </div>

        <%!-- Headline stats --%>
        <section class="members-section">
          <div class="members-section-head">ALL-TIME</div>
          <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px;">
            <div :for={card <- stat_cards(@stats)} style={card.style}>
              <div style="font-family: 'IBM Plex Mono', monospace; font-size: 10px; letter-spacing: 0.12em; color: oklch(0.5 0.02 250); margin-bottom: 6px;">
                {card.label}
              </div>
              <div style="font-family: 'IBM Plex Mono', monospace; font-size: 26px; font-weight: 600; color: oklch(0.3 0.02 250);">
                {card.value}
              </div>
            </div>
          </div>
          <div :if={@stats.total > 0} style="margin-top: 12px; display: flex; gap: 8px;">
            <span :for={{src, n} <- @stats.by_source} class="role-chip">
              {source_label(src)}: {n}
            </span>
          </div>
        </section>

        <%!-- Recent events --%>
        <section class="members-section">
          <div class="members-section-head">RECENT EVENTS</div>
          <div :if={@events == []} class="members-empty">
            No runtime activity yet. Calls to the prompt and deployment APIs will show up here.
          </div>
          <table :if={@events != []} class="members-table">
            <thead>
              <tr>
                <th>WHEN</th>
                <th>SOURCE</th>
                <th>AGENT</th>
                <th>RESOLVED VIA</th>
                <th>PRINCIPAL</th>
                <th>STATUS</th>
                <th>LATENCY</th>
                <th>TOKENS</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={e <- @events}>
                <td class="members-date">{fmt_time(e.inserted_at)}</td>
                <td><span class="role-chip">{source_label(e.source)}</span></td>
                <td>{graph_name(e)}</td>
                <td style="font-family: 'IBM Plex Mono', monospace;">{e.resolved_via || "—"}</td>
                <td style="font-family: 'IBM Plex Mono', monospace;">{e.principal_type && String.upcase(to_string(e.principal_type)) || "—"}</td>
                <td>
                  <span class="role-chip" data-role={e.status == :ok && "editor" || "viewer"}>
                    {e.status == :ok && "OK" || "ERR #{e.http_status}"}
                  </span>
                </td>
                <td class="members-date">{fmt_num(e.latency_ms)}{e.latency_ms && "ms" || ""}</td>
                <td class="members-date">{fmt_num(e.token_estimate)}</td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>
    </Layouts.workspace>
    """
  end

  defp stat_cards(stats) do
    card = "border: 1px solid oklch(0.85 0.02 250); padding: 14px 16px; background: oklch(0.99 0.003 245);"

    [
      %{label: "TOTAL CALLS", value: stats.total, style: card},
      %{label: "SUCCESS RATE", value: (stats.success_rate && "#{stats.success_rate}%") || "—", style: card},
      %{label: "ERRORS", value: stats.errors, style: card},
      %{label: "AVG LATENCY", value: (stats.avg_latency && "#{stats.avg_latency}ms") || "—", style: card}
    ]
  end
end
