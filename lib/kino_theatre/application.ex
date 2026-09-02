defmodule KinoTheatre.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    KinoTheatre.Config.load()
    KinoTheatre.Blocklist.init()
    KinoTheatre.Dictionary.init()
    KinoTheatre.SubtitleCache.init()
    KinoTheatre.Resume.init()
    KinoTheatre.Watchlist.init()

    children = [
      {Registry, keys: :unique, name: KinoTheatre.Remux.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: KinoTheatre.Remux.Supervisor}
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one, name: KinoTheatre.Supervisor)

    # As a Burrito-wrapped release (the standalone binary), booting the app IS
    # the CLI invocation — run it and halt before `elixir start_cli` gets a
    # chance to misread our arguments as a script path. As an escript,
    # escript's main/1 drives instead.
    if Burrito.Util.running_standalone?() do
      KinoTheatre.CLI.main(Burrito.Util.Args.argv())
      System.halt(0)
    end

    result
  end
end
