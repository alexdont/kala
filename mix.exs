defmodule KinoTheatre.MixProject do
  use Mix.Project

  def project do
    [
      app: :kino_app,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: KinoTheatre.CLI, path: "kino"],
      deps: deps()
    ]
  end

  def application do
    [
      mod: {KinoTheatre.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.2"}
    ]
  end
end
