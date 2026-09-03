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

  @doc "The Kitsu anime id for a MyAnimeList id (reverse mapping) — feeds Torrentio's kitsu: anime path."
  def kitsu_id_from_mal(mal) when not is_nil(mal) do
    params = ["filter[externalSite]": "myanimelist/anime", "filter[externalId]": to_string(mal), include: "item"]

    case get("/mappings", params) do
      {:ok, %{"included" => inc}} when is_list(inc) ->
        case Enum.find(inc, &(&1["type"] == "anime")) do
          %{"id" => id} -> {:ok, id}
          _ -> {:error, :no_mapping}
        end

      _ ->
        {:error, :no_mapping}
    end
  rescue
    _ -> {:error, :no_mapping}
  end

  def kitsu_id_from_mal(_), do: {:error, :no_mapping}

  @doc """
  Search anime by text. Returns `{:ok, [anime]}` best-match first.

  AniList is the primary (sub-second, reliable, per-season entries with
  romaji titles and airing-aware episode counts); Kitsu — slow at the best
  of times and 500ing outright for some queries — is only the fallback.
  AniList entries carry no Kitsu id, so the AniDB mapping is unavailable
  for them and tracker search uses the release title (works fine).
  """
  def search(query) do
    case anilist_search(query) do
      {:ok, [_ | _] = results} -> {:ok, results}
      _ -> kitsu_search(query)
    end
  end

  defp kitsu_search(query) do
    case get("/anime", "filter[text]": query, "page[limit]": 5) do
      {:ok, %{"data" => data}} -> {:ok, Enum.map(data, &to_anime/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @anilist_query """
  query($s:String){Page(perPage:6){media(search:$s,type:ANIME){
    id idMal episodes format seasonYear title{romaji english} coverImage{medium}
    nextAiringEpisode{episode}}}}
  """

  defp anilist_search(query) do
    case Req.post("https://graphql.anilist.co",
           json: %{query: @anilist_query, variables: %{s: query}},
           retry: false,
           receive_timeout: 8_000
         ) do
      {:ok, %{status: 200, body: %{"data" => %{"Page" => %{"media" => media}}}}} ->
        {:ok, Enum.map(media, &from_anilist/1)}

      _ ->
        {:error, :anilist_failed}
    end
  end

  # Same shape as to_anime/1 but with no Kitsu id: episode counts come from
  # AniList (or aired-so-far for airing shows), and the AniDB mapping is
  # simply unavailable (source search degrades to text — acceptable).
  defp from_anilist(m) do
    airing = get_in(m, ["nextAiringEpisode", "episode"])
    count = m["episodes"] || (airing && airing - 1)
    romaji = get_in(m, ["title", "romaji"])

    %{
      id: nil,
      anilist_id: m["id"],
      mal_id: m["idMal"],
      title: romaji,
      titles: %{"en_jp" => romaji, "en" => get_in(m, ["title", "english"])},
      episode_count: count,
      subtype: m["format"],
      year: m["seasonYear"] && Integer.to_string(m["seasonYear"]),
      poster: get_in(m, ["coverImage", "medium"])
    }
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
      anilist_id: nil,
      mal_id: nil,
      title: a["canonicalTitle"],
      titles: a["titles"] || %{},
      episode_count: a["episodeCount"],
      subtype: a["subtype"],
      year: year(a["startDate"]),
      poster: get_in(a, ["posterImage", "small"])
    }
  end

  defp to_episode(%{"attributes" => a}) do
    %{number: a["number"], name: a["canonicalTitle"], airdate: a["airdate"]}
  end

  @doc """
  Per-episode metadata for a picked entry: `%{number => %{name, airdate,
  future}}`. AniList carries dates (airingSchedule — past AND upcoming) for
  airing shows and titles (streamingEpisodes) for finished ones; one call
  fetches both. Kitsu-sourced entries use Kitsu's episode list. Best-effort:
  empty map on any failure — the picker just shows bare numbers.
  """
  def episode_details(%{anilist_id: aid}) when is_integer(aid) do
    query = """
    query($id:Int){Media(id:$id){
      airingSchedule(perPage:50){nodes{episode airingAt}}
      streamingEpisodes{title}}}
    """

    case Req.post("https://graphql.anilist.co",
           json: %{query: query, variables: %{id: aid}},
           retry: false,
           receive_timeout: 8_000
         ) do
      {:ok, %{status: 200, body: %{"data" => %{"Media" => media}}}} ->
        titles =
          for %{"title" => t} <- media["streamingEpisodes"] || [],
              [_, n, name] <- [Regex.run(~r/^Episode\s+(\d+)\s*-\s*(.+)$/, t || "")],
              into: %{} do
            {String.to_integer(n), String.trim(name)}
          end

        now = System.os_time(:second)

        schedule =
          for %{"episode" => n, "airingAt" => at} <- get_in(media, ["airingSchedule", "nodes"]) || [],
              into: %{} do
            {n, {at |> DateTime.from_unix!() |> DateTime.to_date() |> Date.to_iso8601(), at > now}}
          end

        numbers = Enum.uniq(Map.keys(titles) ++ Map.keys(schedule))

        Map.new(numbers, fn n ->
          {date, future} = Map.get(schedule, n) || {nil, false}
          {n, %{name: Map.get(titles, n), airdate: date, future: future}}
        end)

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  def episode_details(%{id: kitsu_id}) when is_binary(kitsu_id) do
    {:ok, eps} = episodes(kitsu_id)
    Map.new(eps, fn e -> {e.number, %{name: e.name, airdate: e[:airdate], future: false}} end)
  rescue
    _ -> %{}
  end

  def episode_details(_anime), do: %{}

  defp year(<<y::binary-size(4), _::binary>>), do: y
  defp year(_), do: nil

  defp get(path, params) do
    # kitsu.io is reliable but slow (~3-5s/request). Use a generous timeout so
    # a slow-but-fine response doesn't trip the retry backoff, which would
    # compound two calls into a 20-30s hang.
    # One retry only, logged at debug: Kitsu 500s are routine and the
    # AniList fallback covers them — warnings would just spam the CLI.
    req =
      Req.new(
        base_url: @base,
        headers: @headers,
        retry: :transient,
        max_retries: 1,
        retry_log_level: :debug,
        receive_timeout: 15_000
      )

    case Req.get(req, url: path, params: params) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:kitsu, status}}
      {:error, exception} -> {:error, exception}
    end
  end
end
