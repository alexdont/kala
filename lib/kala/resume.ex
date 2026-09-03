defmodule Kala.Resume do
  @moduledoc """
  Per-title "continue watching" memory: the last season/episode + the exact
  source (torrent) the user played for each movie/show, so they can resume
  without re-hunting the source list. Held in ETS and mirrored to a JSON file so
  it survives server restarts. Time-within-the-episode is remembered separately,
  client-side (localStorage keyed by the remux id), and resumes automatically.

  Entries are plain string-keyed maps (JSON round-trips cleanly):

      %{"type", "tmdb_id", "season", "episode", "title", "poster_path",
        "source" => %{"name", "magnet", "hash"}, "updated_at"}
  """

  @table :resume

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

  @doc "The resume entry for a title, or nil."
  def get(type, tmdb_id) do
    case :ets.lookup(@table, key(type, tmdb_id)) do
      [{_k, entry}] -> entry
      [] -> nil
    end
  end

  @doc "All resume entries, most recently updated first."
  def all do
    @table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1["updated_at"], :desc)
  end

  @doc "Record (or update) where the user is in a title."
  def put(type, tmdb_id, entry) do
    :ets.insert(@table, {key(type, tmdb_id), entry})
    persist()
    :ok
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
    # Persistence is best-effort — never let a write failure break playback.
    _ -> :ok
  end

  defp path do
    dir = Application.get_env(:kala_app, :data_dir) || Path.join(home(), ".kala")
    Path.join(dir, "resume.json")
  end

  defp home do
    case System.user_home() do
      nil -> System.tmp_dir!()
      dir -> dir
    end
  end
end
