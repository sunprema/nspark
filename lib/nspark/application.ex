defmodule Nspark.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    node_js_children =
      if Application.get_env(:live_svelte, :ssr_module, nil) == LiveSvelte.SSR.NodeJS do
        [{NodeJS.Supervisor, [path: LiveSvelte.SSR.NodeJS.server_path(), pool_size: 4]}]
      else
        []
      end

    children = node_js_children ++ [
      NsparkWeb.Telemetry,
      Nspark.Repo,
      {DNSCluster, query: Application.get_env(:nspark, :dns_cluster_query) || :ignore},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:nspark, :ash_domains),
         Application.fetch_env!(:nspark, Oban)
       )},
      {Phoenix.PubSub, name: Nspark.PubSub},
      # Start a worker by calling: Nspark.Worker.start_link(arg)
      # {Nspark.Worker, arg},
      # Start to serve requests, typically the last entry
      NsparkWeb.Endpoint,
      {AshAuthentication.Supervisor, [otp_app: :nspark]}
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Nspark.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    NsparkWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
