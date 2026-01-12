defmodule ElixirIndex.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixir_index,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ElixirIndex.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:broadway, "~> 1.0"},
      {:req, "~> 0.5.0"},
      {:ch, "~> 0.3.0"},
      {:jason, "~> 1.4"}
    ]
  end
end
