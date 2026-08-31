defmodule KinoTheatre.Blocklist do
  @moduledoc """
  Set of torrent hashes known to be unresolvable — mostly Real-Debrid DMCA
  takedowns (HTTP 451 `infringing_file`), which are global and permanent, so
  there's no point retrying them.

  Backed by a public ETS table for lookups and persisted to a hash-per-line
  file, so short-lived CLI runs remember takedowns across invocations.
  """

  @table :rd_blocklist

  def init do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:public, :named_table, :set, read_concurrency: true])
        load()
        @table

      _ref ->
        @table
    end
  end

  def block(hash) when is_binary(hash) do
    hash = norm(hash)

    unless :ets.member(@table, hash) do
      :ets.insert(@table, {hash, true})
      File.mkdir_p!(Path.dirname(path()))
      File.write(path(), hash <> "\n", [:append])
    end

    true
  end

  def blocked?(hash) when is_binary(hash), do: :ets.member(@table, norm(hash))

  def all, do: :ets.tab2list(@table) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

  defp norm(hash), do: String.downcase(hash)

  defp load do
    case File.read(path()) do
      {:ok, data} ->
        data
        |> String.split("\n", trim: true)
        |> Enum.each(&:ets.insert(@table, {&1, true}))

      {:error, _} ->
        :ok
    end
  end

  defp path do
    dir = Application.get_env(:kino_app, :data_dir) || Path.join(System.user_home!(), ".kino")
    Path.join(dir, "blocklist")
  end
end
