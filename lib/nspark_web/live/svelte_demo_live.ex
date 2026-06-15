defmodule NsparkWeb.SvelteDemoLive do
  use NsparkWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <.svelte name="SvelteDemo" props={%{count: @count}} socket={@socket} />
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, count: 0)}
  end

  @impl true
  def handle_event("increment", _params, socket) do
    {:noreply, update(socket, :count, &(&1 + 1))}
  end

  @impl true
  def handle_event("decrement", _params, socket) do
    {:noreply, update(socket, :count, &(&1 - 1))}
  end
end
