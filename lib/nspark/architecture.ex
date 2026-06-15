defmodule Nspark.Architecture do
  @moduledoc """
  The agent architecture domain: graphs and their nodes, edges, and immutable
  version snapshots. See docs/HLD.md §4 for the persistence model.
  """
  use Ash.Domain, otp_app: :nspark, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Nspark.Architecture.Graph
    resource Nspark.Architecture.Node
    resource Nspark.Architecture.Edge
    resource Nspark.Architecture.GraphVersion
  end
end
