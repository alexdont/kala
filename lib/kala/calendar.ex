defmodule Kala.Calendar do
  @moduledoc """
  Release calendar for the watchlist: when episodes of pinned shows/anime
  air, and when pinned movies hit theaters / digital (digital = the moment
  proper WEB releases replace cams).

  Sources — one lookup per watchlist entry, disk-cached 6h:
    * anime  → AniList, searched with status RELEASING/NOT_YET_RELEASED so
      a franchise name resolves to its currently-airing season; the airing
      schedule lists upcoming episodes with exact timestamps.
    * tv     → TMDB's latest season episode list (announced future episodes
      carry air dates).
    * movies → TMDB release dates (earliest digital + theatrical).

  Events are string-keyed maps (JSON round-trip): "date" (ISO), "label",
  "kind" ("episode"|"digital"|"theatrical"), plus enough context to jump
  into the watch flow ("type", "tmdb_id", "title", "season", "episode",
  "anime", "search_title").
  """

  alias Kala.{Tmdb, Watchlist}

  @cache_ttl_s 6 * 3600
  @past_days 7
  @future_days 45

  @doc "All calendar events for the watchlist, window-filtered, date-sorted."
  def events do
    today = Date.utc_today()
    from = Date.add(today, -@past_days)
    to = Date.add(today, @future_days)

    all =
      Watchlist.all()
      |> Task.async_stream(&entry_events/1,
        max_concurrency: 4,
        timeout: 20_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, events} -> events
        _ -> []
      end)

    # Dated events inside the window first; "waiting" events (no date —
    # digital TBA, next season announced) trail the agenda.
    {waiting, dated} = Enum.split_with(all, &is_nil(&1["date"]))

    dated =
      dated
      |> Enum.filter(fn ev ->
        case Date.from_iso8601(ev["date"]) do
          {:ok, d} ->
            # Episodes stay inside the window (weekly volume adds up);
            # movie theatrical/digital dates are rare and worth showing
            # however far out they are.
            not_past = Date.compare(d, from) != :lt
            not_past and (ev["kind"] != "episode" or Date.compare(d, to) != :gt)

          _ ->
            false
        end
      end)
      |> Enum.sort_by(fn ev -> {ev["date"], ev["title"]} end)

    dated ++ Enum.sort_by(waiting, & &1["title"])
  end

  @doc """
  Pre-fetch one entry's schedule into the disk cache, detached — called
  when a title is pinned, so opening the calendar later is all cache hits.
  """
  def warm(entry), do: spawn(fn -> entry_events(entry) end)

  defp entry_events(entry) do
    cached("#{entry["type"]}-#{entry["tmdb_id"]}", fn -> fetch_entry_events(entry) end)
  rescue
    _ -> []
  end

  defp fetch_entry_events(%{"type" => "movie"} = entry) do
    case Tmdb.release_dates(entry["tmdb_id"]) do
      {:ok, %{"results" => results}} ->
        theatrical = earliest_release(results, 3)
        digital = earliest_release(results, 4)

        dated =
          for {kind, date} <- [{"theatrical", theatrical}, {"digital", digital}],
              date != nil do
            %{
              "date" => date,
              "kind" => kind,
              "label" => "#{entry["title"]} — #{kind} release",
              "type" => "movie",
              "tmdb_id" => entry["tmdb_id"],
              "title" => entry["title"]
            }
          end

        # In theaters, digital date unannounced: the classic waiting-for-
        # the-WEB-release limbo — worth a calendar line of its own.
        waiting =
          if digital == nil and theatrical != nil and theatrical <= Date.to_iso8601(Date.utc_today()) do
            [
              %{
                "date" => nil,
                "kind" => "waiting",
                "label" => "#{entry["title"]} — in theaters since #{theatrical}, digital TBA",
                "type" => "movie",
                "tmdb_id" => entry["tmdb_id"],
                "title" => entry["title"]
              }
            ]
          else
            []
          end

        dated ++ waiting

      _ ->
        []
    end
  end

  defp fetch_entry_events(%{"type" => "tv"} = entry) do
    case Tmdb.tv(entry["tmdb_id"]) do
      {:ok, details} ->
        if anime?(details),
          do: anime_events(entry, details),
          else: tv_events(entry, details)

      _ ->
        []
    end
  end

  defp fetch_entry_events(_entry), do: []

  defp tv_events(entry, details) do
    if details["status"] in ["Ended", "Canceled"] do
      []
    else
      seasons =
        details["seasons"]
        |> List.wrap()
        |> Enum.filter(&(&1["season_number"] > 0))
        |> Enum.map(& &1["season_number"])
        |> Enum.sort(:desc)

      # TMDB often lists a placeholder next season (announced, zero dated
      # episodes) above the one actually airing — scan the last couple of
      # seasons and use the first with real air dates.
      dated =
        seasons
        |> Enum.take(2)
        |> Enum.find_value([], fn season ->
          case season_events(entry, season) do
            [] -> nil
            events -> events
          end
        end)

      case {dated, seasons} do
        {[], [latest | _]} ->
          [
            %{
              "date" => nil,
              "kind" => "waiting",
              "label" => "#{entry["title"]} S#{pad(latest)} — announced, dates TBA",
              "type" => "tv",
              "tmdb_id" => entry["tmdb_id"],
              "title" => entry["title"]
            }
          ]

        {dated, _} ->
          dated
      end
    end
  end

  defp season_events(entry, season) do
    case Tmdb.season(entry["tmdb_id"], season) do
      {:ok, %{"episodes" => episodes}} ->
        for e <- episodes, e["air_date"] not in [nil, ""] do
          %{
            "date" => e["air_date"],
            "kind" => "episode",
            "label" => "#{entry["title"]} S#{pad(season)}E#{pad(e["episode_number"])}",
            "type" => "tv",
            "tmdb_id" => entry["tmdb_id"],
            "title" => entry["title"],
            "season" => season,
            "episode" => e["episode_number"]
          }
        end

      _ ->
        []
    end
  end

  @anime_query """
  query($s:String){Media(search:$s,type:ANIME,status_in:[RELEASING,NOT_YET_RELEASED]){
    title{romaji}
    airingSchedule(notYetAired:true,perPage:12){nodes{episode airingAt}}}}
  """

  defp anime_events(entry, _details) do
    case Req.post("https://graphql.anilist.co",
           json: %{query: @anime_query, variables: %{s: entry["title"]}},
           retry: false,
           receive_timeout: 8_000
         ) do
      {:ok, %{status: 200, body: %{"data" => %{"Media" => %{"airingSchedule" => sched} = media}}}} ->
        romaji = get_in(media, ["title", "romaji"]) || entry["title"]

        for %{"episode" => n, "airingAt" => at} <- sched["nodes"] || [] do
          %{
            "date" => at |> DateTime.from_unix!() |> DateTime.to_date() |> Date.to_iso8601(),
            "kind" => "episode",
            "label" => "#{romaji} E#{pad(n)}",
            "type" => "tv",
            "tmdb_id" => entry["tmdb_id"],
            "title" => entry["title"],
            "episode" => n,
            "anime" => true,
            "search_title" => romaji
          }
        end

      _ ->
        []
    end
  end

  # Earliest release of a TMDB type (3 theatrical, 4 digital) across regions.
  defp earliest_release(results, type_id) do
    results
    |> Enum.flat_map(&(&1["release_dates"] || []))
    |> Enum.filter(&(&1["type"] == type_id and is_binary(&1["release_date"])))
    |> Enum.map(&String.slice(&1["release_date"], 0, 10))
    |> Enum.min(fn -> nil end)
  end

  defp anime?(%{"original_language" => "ja", "genres" => genres}) when is_list(genres),
    do: Enum.any?(genres, &(&1["id"] == 16))

  defp anime?(_details), do: false

  defp pad(n), do: String.pad_leading("#{n}", 2, "0")

  @doc """
  The next-7-days pulse, from the disk cache ONLY — never fetches, so the
  home screen stays instant. Stale/missing entries are re-warmed in the
  background for the next launch. Includes yesterday (things that just
  dropped). Dated events only, sorted.
  """
  def cached_events do
    today = Date.utc_today()
    from = Date.add(today, -1)
    to = Date.add(today, 7)
    fresh_after = System.os_time(:second) - @cache_ttl_s

    Watchlist.all()
    |> Enum.flat_map(fn entry ->
      path = cache_path("#{entry["type"]}-#{entry["tmdb_id"]}")

      case File.read(path) do
        {:ok, body} ->
          case File.stat(path, time: :posix) do
            {:ok, %{mtime: mtime}} when mtime > fresh_after -> :ok
            _ -> warm(entry)
          end

          case Jason.decode(body) do
            {:ok, events} when is_list(events) -> events
            _ -> []
          end

        _ ->
          warm(entry)
          []
      end
    end)
    |> Enum.filter(fn ev ->
      case Date.from_iso8601(ev["date"] || "") do
        {:ok, d} -> Date.compare(d, from) != :lt and Date.compare(d, to) != :gt
        _ -> false
      end
    end)
    |> Enum.sort_by(& &1["date"])
  rescue
    _ -> []
  end

  defp cache_path(cache_key) do
    dir = Path.join(System.tmp_dir!(), "kala-calendar")
    File.mkdir_p!(dir)
    key = :erlang.md5(cache_key) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    Path.join(dir, key)
  end

  defp cached(cache_key, fetch) do
    path = cache_path(cache_key)
    fresh_after = System.os_time(:second) - @cache_ttl_s

    with {:ok, %{mtime: mtime}} when mtime > fresh_after <- File.stat(path, time: :posix),
         {:ok, body} <- File.read(path),
         {:ok, events} when is_list(events) <- Jason.decode(body) do
      events
    else
      _ ->
        events = fetch.()
        File.write(path, Jason.encode!(events))
        events
    end
  end

  # (cache dir creation lives in cache_path/1)
end
