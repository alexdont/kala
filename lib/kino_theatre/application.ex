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

    children = [
      {Registry, keys: :unique, name: KinoTheatre.Remux.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: KinoTheatre.Remux.Supervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: KinoTheatre.Supervisor)
  end
end
