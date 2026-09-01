defmodule KinoTheatre.Kitsu do
  @moduledoc """
  Anime-native metadata from Kitsu (kitsu.io JSON:API) — our equivalent of the
  Stremio "Anime Kitsu" addon. Used to get proper episode lists (with absolute
  numbering) and release titles for anime that TMDB covers poorly or not at all.
  """

  @base "https://kitsu.io/api/edge"
  @headers [{"accept", "application/vnd.api+json"}]
  @page 20

  @doc "The AniDB anime id mapped to a Kitsu anime — lets us query trackers by the exact show."
  def anidb_id(kitsu_id) do
    case get("/anime/#{kitsu_id}/mappings", "filter[externalSite]": "anidb") do
      {:ok, %{"data" => [%{"attributes" => %{"externalId" => id}} | _]}} -> {:ok, id}
      {:ok, _} -> {:error, :no_mapping}
      error -> error
    end
  end

  @doc "The MyAnimeList id mapped to a Kitsu anime — the key AniSkip timestamps use."
  def mal_id(kitsu_id) do
    case get("/anime/#{kitsu_id}/mappings", "filter[externalSite]": "myanimelist/anime") do
      {:ok, %{"data" => [%{"attributes" => %{"externalId" => id}} | _]}} -> {:ok, id}
      {:ok, _} -> {:error, :no_mapping}
      error -> error
    end
  end

  @doc "Search anime by text. Returns `{:ok, [anime]}` best-match first."
  def search(query) do
    case get("/anime", "filter[text]": query, "page[limit]": 5) do
      {:ok, %{"data" => data}} -> {:ok, Enum.map(data, &to_anime/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  All episodes for a Kitsu anime id, sorted by number. Pages through the API
  up to `opts[:max]` episodes (default 500) so long-running shows don't spin
  forever. Episodes without a number (specials/recaps) are dropped.
  """
  def episodes(anime_id, opts \\ []) do
    max = Keyword.get(opts, :max, 500)
    {:ok, fetch_episodes(anime_id, 0, max, [])}
  end

  defp fetch_episodes(id, offset, max, acc) when offset < max do
    case get("/anime/#{id}/episodes", "page[limit]": @page, "page[offset]": offset, sort: "number") do
      {:ok, %{"data" => data}} when data != [] ->
        acc = acc ++ Enum.map(data, &to_episode/1)

        if length(data) < @page,
          do: finalize(acc),
          else: fetch_episodes(id, offset + @page, max, acc)

      _ ->
        finalize(acc)
    end
  end

  defp fetch_episodes(_id, _offset, _max, acc), do: finalize(acc)

  defp finalize(episodes) do
    episodes
    |> Enum.reject(&is_nil(&1.number))
    |> Enum.sort_by(& &1.number)
  end

  # Prefer romaji (en_jp) for Nyaa queries — fansub groups favor it — then
  # English, then canonical.
  def release_title(%{titles: titles, title: canonical}) do
    titles["en_jp"] || titles["en"] || canonical
  end

  defp to_anime(%{"id" => id, "attributes" => a}) do
    %{
      id: id,
      title: a["canonicalTitle"],
      titles: a["titles"] || %{},
      episode_count: a["episodeCount"],
      subtype: a["subtype"],
      year: year(a["startDate"]),
      poster: get_in(a, ["posterImage", "small"])
    }
  end

  defp to_episode(%{"attributes" => a}) do
    %{number: a["number"], name: a["canonicalTitle"]}
  end

  defp year(<<y::binary-size(4), _::binary>>), do: y
  defp year(_), do: nil

  defp get(path, params) do
    # kitsu.io is reliable but slow (~3-5s/request). Use a generous timeout so
    # a slow-but-fine response doesn't trip the retry backoff, which would
    # compound two calls into a 20-30s hang.
    req = Req.new(base_url: @base, headers: @headers, retry: :transient, max_retries: 2, receive_timeout: 30_000)

    case Req.get(req, url: path, params: params) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:kitsu, status}}
      {:error, exception} -> {:error, exception}
    end
  end
end
