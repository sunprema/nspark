defmodule Nspark.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :nspark,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Elixir client for Newtonian Spark runtime prompt delivery",
      package: package(),
      name: "Nspark",
      docs: [main: "Nspark", source_ref: "v#{@version}"]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.2"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/sunprema/nspark"},
      files: ~w(lib mix.exs README.md .formatter.exs)
    ]
  end
end
