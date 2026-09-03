defmodule Kala.SubtitleCache do
  @moduledoc """
  In-memory cache of converted subtitle VTT, keyed by source. Prevents
  re-downloading the same subtitle on every page reload — important for
  OpenSubtitles, whose downloads count against a small daily quota.
  """

  @table :subtitle_cache

  def init do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:public, :named_table, :set, read_concurrency: true])
      _ref -> @table
    end
  end

  @doc "Return the cached VTT for `key`, else run `fun` (`-> {:ok, vtt} | {:error, _}`) and cache success."
  def fetch(key, fun) do
    case :ets.lookup(@table, key) do
      [{^key, vtt}] ->
        {:ok, vtt}

      [] ->
        with {:ok, vtt} <- fun.() do
          :ets.insert(@table, {key, vtt})
          {:ok, vtt}
        end
    end
  end
end
