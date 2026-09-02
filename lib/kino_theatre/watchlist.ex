defmodule KinoTheatre.Watchlist do
  @moduledoc """
  The user's curated to-watch list — intent, as opposed to `Resume`'s
  automatic history. Titles are pinned/unpinned with ctrl-s from any title
  picker and browsed from the main menu. ETS mirrored to JSON, same pattern
  as `Resume`.

  Entries are plain string-keyed maps:

      %{"type", "tmdb_id", "title", "year", "poster", "added_at"}
  """

  @table :watchlist

  def init do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:public, :named_table, :set, read_concurrency: true])
        load()

      _ref ->
        @table
    end
  end

  def key(type, tmdb_id), do: "#{type}:#{tmdb_id}"

  def has?(type, tmdb_id), do: :ets.member(@table, key(type, tmdb_id))

  @doc "All watchlist entries, most recently added first."
  def all do
    @table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1["added_at"], :desc)
  end

  def count, do: :ets.info(@table, :size)

  @doc "Pin a title (from a TMDB title map: type/id/title/year/poster)."
  def add(title) do
    entry = %{
      "type" => title.type,
      "tmdb_id" => title.id,
      "title" => title.title,
      "year" => title.year,
      "poster" => Map.get(title, :poster),
      "added_at" => System.os_time(:second)
    }

    :ets.insert(@table, {key(title.type, title.id), entry})
    persist()
    :ok
  end

  def remove(type, tmdb_id) do
    :ets.delete(@table, key(type, tmdb_id))
    persist()
    :ok
  end

  @doc "Pin if unpinned, unpin if pinned. Returns :added | :removed."
  def toggle(title) do
    if has?(title.type, title.id) do
      remove(title.type, title.id)
      :removed
    else
      add(title)
      :added
    end
  end

  defp load do
    with {:ok, body} <- File.read(path()),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      Enum.each(map, fn {k, v} -> :ets.insert(@table, {k, v}) end)
    end

    @table
  end

  defp persist do
    data = @table |> :ets.tab2list() |> Map.new()
    File.mkdir_p!(Path.dirname(path()))
    File.write(path(), Jason.encode!(data))
  rescue
    _ -> :ok
  end

  defp path do
    dir = Application.get_env(:kino_app, :data_dir) || Path.join(home(), ".kino")
    Path.join(dir, "watchlist.json")
  end

  defp home do
    case System.user_home() do
      nil -> System.tmp_dir!()
      dir -> dir
    end
  end
end
