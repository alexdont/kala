defmodule KinoTheatre.MixProject do
  use Mix.Project

  def project do
    [
      app: :kino_app,
      version: "0.1.17",
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
        steps: [:assemble, &clean_stale_erts/1, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_x86_64: [os: :linux, cpu: :x86_64],
            macos_aarch64: [os: :darwin, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end

  # Burrito unpacks ERTS bundles into /tmp/unpacked_erts_* (~131MB each) and
  # never deletes them — a dozen releases fill a tmpfs and the build dies
  # with "disk quota exceeded". Sweep the leftovers before each wrap.
  defp clean_stale_erts(release) do
    System.tmp_dir!()
    |> Path.join("unpacked_erts_*")
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf/1)

    release
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
