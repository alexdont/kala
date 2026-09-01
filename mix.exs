defmodule KinoTheatre.MixProject do
  use Mix.Project

  def project do
    [
      app: :kino_app,
      version: "0.1.8",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: KinoTheatre.CLI, path: "kino"],
      releases: releases(),
      deps: deps()
    ]
  end

  # `MIX_ENV=prod mix release kino` → burrito_out/kino_linux_x86_64:
  # a single self-contained binary (BEAM bundled, no Erlang needed on the
  # user's machine) — the artifact package managers ship.
  defp releases do
    [
      kino: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_x86_64: [os: :linux, cpu: :x86_64],
            macos_aarch64: [os: :darwin, cpu: :aarch64]
          ]
        ]
      ]
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
      {:jason, "~> 1.2"},
      {:burrito, "~> 1.0"}
    ]
  end
end
