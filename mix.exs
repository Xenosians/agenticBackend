defmodule ItsmBackend.MixProject do
  use Mix.Project

  def project do
    [
      app: :itsm_backend,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      mod: {ItsmBackend.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8.13"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:jsonschex, "~> 0.9"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:cors_plug, "~> 3.0"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "test"
      ]
    ]
  end
end
