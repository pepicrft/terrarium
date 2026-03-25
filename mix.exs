defmodule Terrarium.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/pepicrft/terrarium"

  def project do
    [
      app: :terrarium,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      name: "Terrarium",
      description: "An Elixir abstraction for provisioning and interacting with sandbox environments",
      source_url: @source_url,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssh]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Command execution with child process shutdown propagation
      {:muontrap, "~> 1.7"},

      # Telemetry
      {:telemetry, "~> 1.0"},

      # Development & Testing
      {:quokka, "~> 2.12", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "Terrarium",
      extras: ["README.md"],
      source_ref: @version,
      source_url: @source_url,
      groups_for_modules: [
        Core: [
          Terrarium,
          Terrarium.Peer,
          Terrarium.Sandbox,
          Terrarium.Telemetry
        ],
        Behaviours: [
          Terrarium.Provider
        ],
        Providers: [
          Terrarium.Providers.Local,
          Terrarium.Providers.SSH
        ]
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE MIT.md)
    ]
  end

  defp aliases do
    [
      lint: ["format --check-formatted", "credo --strict", "dialyzer"]
    ]
  end
end
