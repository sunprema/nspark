defmodule Nspark.Registry.AssetStatus do
  @moduledoc "Lifecycle status shared by registry assets."
  use Ash.Type.Enum, values: [:draft, :published, :deprecated]
end
