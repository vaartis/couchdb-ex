defmodule CouchDBEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :couchdb_ex,
      version: "0.1.3",
      elixir: "~> 1.6",
      package: package(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [coveralls: :test, "coveralls.travis": :test]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [
        :logger,
        :httpoison
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:httpoison, "~> 1.0"},
      {:poison, "~> 3.1"},

      {:dialyxir, "~> 0.5", only: :dev, runtime: false},
      {:ex_doc, "~> 0.16", only: :dev, runtime: false},
      {:credo, "~> 0.3", only: :dev},

      {:excoveralls, "~> 0.8", only: :test, runtime: false}
    ]
  end

  defp package do
    [
      description: "A supposed-to-be-good CouchDB interface for elixir",
      maintainers: ["vaartis"],
      licenses: ["BSD-2-Clause"],
      links: %{
        "GitHub" => "https://github.com/vaartis/couchdb-ex"
      }
    ]
  end

end
