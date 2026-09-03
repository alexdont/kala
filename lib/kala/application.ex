defmodule Kala.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    migrate_from_kino()
    Kala.Config.load()
    Kala.Blocklist.init()
    Kala.Dictionary.init()
    Kala.SubtitleCache.init()
    Kala.Resume.init()
    Kala.Watchlist.init()

    children = [
      {Registry, keys: :unique, name: Kala.Remux.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Kala.Remux.Supervisor}
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one, name: Kala.Supervisor)

    # As a Burrito-wrapped release (the standalone binary), booting the app IS
    # the CLI invocation — run it and halt before `elixir start_cli` gets a
    # chance to misread our arguments as a script path. As an escript,
    # escript's main/1 drives instead.
    if Burrito.Util.running_standalone?() do
      Kala.CLI.main(Burrito.Util.Args.argv())
      System.halt(0)
    end

    result
  end

  # One-time rename migration: adopt the old ~/.config/kino/config and
  # ~/.kino data dir (positions, tracks, resume, watchlist, blocklist) when
  # the new kala locations don't exist yet. Best-effort — never blocks boot.
  defp migrate_from_kino do
    home = System.user_home!()
    config_home = System.get_env("XDG_CONFIG_HOME") || Path.join(home, ".config")

    migrate_dir(Path.join(config_home, "kino"), Path.join(config_home, "kala"))
    migrate_dir(Path.join(home, ".kino"), Path.join(home, ".kala"))
  rescue
    _ -> :ok
  end

  defp migrate_dir(old, new) do
    if File.dir?(old) and not File.exists?(new) do
      File.cp_r(old, new)
    end
  end
end
