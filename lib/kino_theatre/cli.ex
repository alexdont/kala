defmodule KinoTheatre.CLI do
  @moduledoc """
  The `kino` command-line interface.

  Emits JSON on stdout (one document per invocation) so frontends — the
  Omarchy overlay, scripts, a future TUI — can consume it. `--pretty` renders
  a human-readable listing instead.
  """

  alias KinoTheatre.{Config, Player, RD, Sources, Tmdb}

  @backends %{"apibay" => :apibay, "nyaa" => :nyaa, "anime" => :anime}

  def main(argv) do
    case argv do
      ["search" | rest] -> search(rest)
      ["watch" | rest] -> watch(rest)
      ["featured" | _] -> featured()
      ["continue" | _] -> continue()
      ["resolve" | rest] -> resolve(rest)
      ["play" | rest] -> play(rest)
      ["config" | _] -> config()
      ["help" | _] -> usage(0)
      ["--help" | _] -> usage(0)
      [] -> usage(1)
      [other | _] -> die("unknown command: #{other} (try: kino help)")
    end
  end

  # True when stdout is a terminal (a human), false when piped (a frontend).
  defp tty?, do: IO.ANSI.enabled?()

  # ── search ────────────────────────────────────────────────────────

  defp search(argv) do
    {opts, query} = search_args(argv, "search")
    sources = run_search(query, opts)

    pretty? = opts[:pretty] || (tty?() and !opts[:json])

    if pretty? do
      print_sources(sources)
      IO.puts(:stderr, ~s(\nto pick one and play it: kino watch "#{query}"))
    else
      IO.puts(Jason.encode!(sources))
    end
  end

  defp search_args(argv, cmd) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [backend: :string, limit: :integer, pretty: :boolean, json: :boolean]
      )

    check_invalid(invalid)
    query = Enum.join(args, " ")
    if query == "", do: die(~s(#{cmd} needs a query: kino #{cmd} "the matrix"))
    {opts, query}
  end

  defp run_search(query, opts) do
    backend =
      Map.get(@backends, opts[:backend] || "apibay") ||
        die("unknown backend: #{opts[:backend]} (apibay | nyaa | anime)")

    case Sources.search(query, backend: backend) do
      {:ok, sources} ->
        if opts[:limit], do: Enum.take(sources, opts[:limit]), else: sources

      {:error, reason} ->
        die("search failed: #{inspect(reason)}")
    end
  end

  defp print_sources([]), do: IO.puts("no sources found")

  defp print_sources(sources) do
    sources
    |> Enum.with_index(1)
    |> Enum.each(fn {s, i} ->
      IO.puts(String.pad_leading("#{i}", 3) <> ". " <> describe(s))
    end)
  end

  # ── watch (interactive) ───────────────────────────────────────────

  defp watch(argv) do
    {opts, query} = watch_args(argv)

    unless RD.configured?() do
      die("RD_TOKEN is not set — add it to #{Config.path()} or the environment")
    end

    cond do
      opts[:raw] ->
        watch_raw(query, opts)

      not Tmdb.configured?() ->
        IO.puts(:stderr, "TMDB_API_KEY not set — falling back to raw torrent search")
        watch_raw(query, opts)

      true ->
        watch_title(query)
    end
  end

  defp watch_args(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [backend: :string, limit: :integer, raw: :boolean]
      )

    check_invalid(invalid)
    query = Enum.join(args, " ")
    if query == "", do: die(~s(watch needs a query: kino watch "the matrix"))
    {opts, query}
  end

  defp watch_raw(query, opts) do
    case run_search(query, opts) do
      [] -> die("no sources found for \"#{query}\"")
      sources -> probe_and_pick(sources, [], nil)
    end
  end

  # The title-first flow: TMDB titles → (season → episode for TV) → sources.
  defp watch_title(query) do
    # A trailing year ("in the gray 2026") kills TMDB's text match — strip it
    # and use it to rank instead (soft, ±1: release dates shift).
    {q, year} = split_year(query)
    title = pick_title(q, year, 1, []) || System.halt(0)
    play_title(title)
  end

  # Everything downstream of "which title": details → (episodes) → sources.
  defp play_title(title) do
    details =
      case fetch_details(title) do
        {:ok, details} -> details
        {:error, reason} -> die("TMDB lookup failed: #{inspect(reason)}")
      end

    imdb = Tmdb.imdb_id(details)

    {season, episode} =
      case title.type do
        "movie" -> {nil, nil}
        "tv" -> pick_episode(details)
      end

    ctx = %{
      type: title.type,
      tmdb_id: title.id,
      title: title.title,
      season: season,
      episode: episode,
      poster_path: details["poster_path"]
    }

    title.type
    |> title_sources(title.title, title.year, imdb, season, episode)
    |> probe_and_pick(rd_opts(season, episode), ctx)
  end

  defp title_sources("movie", name, year, imdb, _season, _episode) do
    q = Enum.join(Enum.reject([name, year], &is_nil/1), " ")
    with_library(q, find_sources(q, imdb && {:movie, imdb}))
  end

  defp title_sources("tv", name, _year, imdb, season, episode) do
    q = Sources.episode_query(name, season, episode)
    with_library(q, find_sources(q, imdb && {:series, imdb, season, episode}))
  end

  # Torrents already in the user's debrid account come first — instant and
  # guaranteed to play. Dedup by hash, keeping the library entry.
  defp with_library(query, found) do
    library = query |> RD.library() |> Enum.map(&Sources.account_source/1)
    Enum.uniq_by(library ++ found, & &1.hash)
  end

  defp rd_opts(season, episode) do
    Enum.reject([season: season, episode: episode], fn {_k, v} -> is_nil(v) end)
  end

  # ── featured (trending on TMDB) ───────────────────────────────────

  defp featured do
    unless RD.configured?() do
      die("RD_TOKEN is not set — add it to #{Config.path()} or the environment")
    end

    unless Tmdb.configured?() do
      die("featured needs TMDB_API_KEY — add it to #{Config.path()} or the environment")
    end

    type =
      case pick(["movies", "shows"], &String.capitalize/1, "what are you in the mood for?") do
        "movies" -> "movie"
        "shows" -> "tv"
        nil -> System.halt(0)
      end

    title = pick_featured(type, 1, []) || System.halt(0)
    play_title(title)
  end

  defp pick_featured(type, page, acc) do
    {results, more?} =
      case Tmdb.trending(type, page) do
        {:ok, results, more?} -> {results, more?}
        {:error, reason} -> die("TMDB trending failed: #{inspect(reason)}")
      end

    titles = Enum.uniq_by(acc ++ results, &{&1.type, &1.id})
    items = if more?, do: titles ++ [:more], else: titles
    label = if type == "movie", do: "movies", else: "shows"

    case pick(items, &describe_title_item/1, "trending #{label} this week") do
      :more -> pick_featured(type, page + 1, titles)
      other -> other
    end
  end

  defp split_year(query) do
    case Regex.run(~r/^(.*?)\s+((?:19|20)\d{2})\s*$/, String.trim(query)) do
      [_, rest, year] when rest != "" -> {rest, String.to_integer(year)}
      _ -> {query, nil}
    end
  end

  # Show a page of TMDB titles (year-matches first when a year was given),
  # with a "more results" entry while further pages exist.
  # TMDB does not cross-match British/American spellings ("In the Grey" is
  # invisible to a "gray" query), so search every spelling variant and merge.
  @spelling_pairs [
    {"gray", "grey"},
    {"color", "colour"},
    {"theater", "theatre"},
    {"harbor", "harbour"},
    {"armor", "armour"},
    {"honor", "honour"}
  ]

  defp spelling_variants(q) do
    d = String.downcase(q)

    extra =
      Enum.flat_map(@spelling_pairs, fn {a, b} ->
        cond do
          String.contains?(d, a) -> [String.replace(d, a, b)]
          String.contains?(d, b) -> [String.replace(d, b, a)]
          true -> []
        end
      end)

    Enum.uniq([q | extra])
  end

  defp canonical(s) do
    d = s |> String.trim() |> String.downcase()
    Enum.reduce(@spelling_pairs, d, fn {a, b}, acc -> String.replace(acc, b, a) end)
  end

  defp pick_title(q, year, page, acc) do
    {results, more?} =
      q
      |> spelling_variants()
      |> Enum.map(fn variant ->
        case Tmdb.search(variant, page) do
          {:ok, results, more?} -> {results, more?}
          {:error, reason} -> die("TMDB search failed: #{inspect(reason)}")
        end
      end)
      |> then(fn pages ->
        {Enum.flat_map(pages, &elem(&1, 0)), Enum.any?(pages, &elem(&1, 1))}
      end)

    titles = Enum.uniq_by(acc ++ results, &{&1.type, &1.id})

    cond do
      titles == [] and not more? ->
        die("no movies or shows on TMDB match \"#{q}\"")

      titles == [] ->
        pick_title(q, year, page + 1, acc)

      true ->
        titles = rank_titles(titles, q, year)
        items = if more?, do: titles ++ [:more], else: titles

        header =
          "what to watch? (#{length(titles)} results" <>
            if(more?, do: ", more available)", else: ", all shown)")

        case pick(items, &describe_title_item/1, header) do
          :more -> pick_title(q, year, page + 1, titles)
          other -> other
        end
    end
  end

  # Exact-title matches first (newest first — a remake outranks the original),
  # then the rest by TMDB popularity. A requested year trumps both, softly
  # (±1: release dates shift between regions and announcements).
  defp rank_titles(titles, query, year) do
    q = canonical(query)

    Enum.sort_by(titles, fn t ->
      yr = t.year && String.to_integer(t.year)

      year_rank =
        cond do
          year == nil -> 0
          yr == year -> 0
          is_integer(yr) and abs(yr - year) <= 1 -> 1
          true -> 2
        end

      if canonical(t.title || "") == q do
        {year_rank, 0, -(yr || 0)}
      else
        {year_rank, 1, -(t.popularity || 0)}
      end
    end)
  end

  defp describe_title_item(:more), do: "⋯ more results"
  defp describe_title_item(title), do: describe_title(title)

  defp fetch_details(%{type: "movie", id: id}), do: Tmdb.movie(id)
  defp fetch_details(%{type: "tv", id: id}), do: Tmdb.tv(id)

  defp pick_episode(details) do
    seasons = Enum.filter(details["seasons"] || [], &(&1["season_number"] > 0))
    if seasons == [], do: die("TMDB lists no seasons for this show")

    season = pick(seasons, &describe_season/1, "which season?") || System.halt(0)
    season_number = season["season_number"]

    episodes =
      case Tmdb.season(details["id"], season_number) do
        {:ok, %{"episodes" => episodes}} when episodes != [] -> episodes
        {:ok, _} -> die("TMDB lists no episodes for season #{season_number}")
        {:error, reason} -> die("TMDB season lookup failed: #{inspect(reason)}")
      end

    episode = pick(episodes, &describe_episode/1, "which episode?") || System.halt(0)
    {season_number, episode["episode_number"]}
  end

  defp find_sources(query, torrentio) do
    IO.puts(:stderr, "searching sources: #{query}")
    opts = if torrentio, do: [backend: :apibay, torrentio: torrentio], else: [backend: :apibay]

    case Sources.search(query, opts) do
      {:ok, []} -> die("no sources found for \"#{query}\"")
      {:ok, sources} -> sources
      {:error, reason} -> die("source search failed: #{inspect(reason)}")
    end
  end

  defp describe_title(t) do
    kind = if t.type == "tv", do: "series", else: "movie"
    rating = if t.vote && t.vote > 0, do: " · ★#{Float.round(t.vote * 1.0, 1)}"
    "#{t.title} (#{t.year || "?"}) · #{kind}#{rating}"
  end

  defp describe_season(s) do
    count = if s["episode_count"], do: " · #{s["episode_count"]} episodes"
    "S#{pad2(s["season_number"])} #{s["name"]}#{count}"
  end

  defp describe_episode(e) do
    date = if e["air_date"] not in [nil, ""], do: " · #{e["air_date"]}"
    "E#{pad2(e["episode_number"])} #{e["name"]}#{date}"
  end

  defp pad2(n), do: String.pad_leading("#{n}", 2, "0")

  # Probe sources on RD one page at a time and only offer the ones that
  # actually play. A playable entry carries its resolved stream, so Enter
  # plays instantly. Playable finds carry over between pages; probing more
  # is an explicit picker choice, not an endless background churn.
  @probe_page 8

  defp probe_and_pick(sources, rd_opts, ctx, playable_so_far \\ [])

  defp probe_and_pick([], _rd_opts, _ctx, []) do
    die("no playable sources — try another title or release")
  end

  defp probe_and_pick(sources, rd_opts, ctx, playable_so_far) do
    {page, rest} = Enum.split(sources, @probe_page)

    IO.puts(
      :stderr,
      "checking #{length(page)} sources (#{length(rest)} more unchecked)…"
    )

    parent = self()

    notify = fn {:result, index, source, result} ->
      case result do
        {:ok, stream} ->
          IO.puts(:stderr, "  ✓ #{source.name}")
          send(parent, {:playable, index, source, stream})

        {:error, reason} ->
          IO.puts(:stderr, "  ✗ #{source.name} — #{unplayable_reason(reason)}")
      end
    end

    RD.probe_sources(Enum.with_index(page), Keyword.put(rd_opts, :notify, notify))
    playable = playable_so_far ++ collect_playable()

    case {playable, rest} do
      {[], []} ->
        die("no playable sources — try another title or release")

      {[], rest} ->
        IO.puts(:stderr, "none playable yet — checking the next page…")
        probe_and_pick(rest, rd_opts, ctx, [])

      {playable, rest} ->
        items = if rest == [], do: playable, else: playable ++ [:more]

        case pick(items, &describe_playable/1, "which source? (all checked + playable)") do
          nil ->
            System.halt(0)

          :more ->
            probe_and_pick(rest, rd_opts, ctx, playable)

          {source, stream} ->
            Player.open(:mpv, stream.url)
            save_resume(ctx, source)
            IO.puts(:stderr, "playing in mpv: #{stream.filename}")
        end
    end
  end

  # Remember what was played (episode + exact source) so `kino continue`
  # can jump straight back without re-hunting sources.
  defp save_resume(nil, _source), do: :ok

  defp save_resume(ctx, source) do
    entry = %{
      "type" => ctx.type,
      "tmdb_id" => ctx.tmdb_id,
      "season" => ctx.season,
      "episode" => ctx.episode,
      "title" => ctx.title,
      "poster_path" => ctx[:poster_path],
      "source" => %{"name" => source.name, "magnet" => source.magnet, "hash" => source.hash},
      "updated_at" => System.os_time(:second)
    }

    KinoTheatre.Resume.put(ctx.type, ctx.tmdb_id, entry)
  end

  defp describe_playable(:more), do: "⋯ check more sources"
  defp describe_playable({source, _stream}), do: describe(source)

  defp collect_playable(acc \\ []) do
    receive do
      {:playable, index, source, stream} -> collect_playable([{index, source, stream} | acc])
    after
      0 ->
        acc
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {_index, source, stream} -> {source, stream} end)
    end
  end

  defp unplayable_reason({:not_cached, _status, _progress}), do: "not cached on Real-Debrid"
  defp unplayable_reason(:known_blocked), do: "blocked (known DMCA takedown)"
  defp unplayable_reason({:rd, 451, _}), do: "infringing — taken down"
  defp unplayable_reason(:no_video_files), do: "no video file in the torrent"
  defp unplayable_reason(:magnet_error), do: "bad magnet link"
  defp unplayable_reason(:no_seeders), do: "dead torrent — no seeders"

  defp unplayable_reason({:torrent_status, "error"}),
    do: "RD couldn't download it (usually no seeders)"

  defp unplayable_reason({:torrent_status, status}), do: "RD download failed (#{status})"
  defp unplayable_reason({:download_timeout, pct}), do: "RD download timed out at #{pct}%"
  defp unplayable_reason({:rd, status, _}), do: "Real-Debrid error #{status}"
  defp unplayable_reason(reason), do: inspect(reason)

  # ── continue watching ─────────────────────────────────────────────

  defp continue do
    unless RD.configured?() do
      die("RD_TOKEN is not set — add it to #{Config.path()} or the environment")
    end

    entries = KinoTheatre.Resume.all()
    if entries == [], do: die("nothing to continue — play something with kino watch first")

    entry = pick(entries, &describe_resume/1, "continue watching") || System.halt(0)
    rd_opts = rd_opts(entry["season"], entry["episode"])
    source = entry["source"]

    IO.puts(:stderr, "trying the source you last played: #{source["name"]}")

    case RD.resolve_magnet(source["magnet"], rd_opts) do
      {:ok, stream} ->
        Player.open(:mpv, stream.url)
        KinoTheatre.Resume.put(
          entry["type"],
          entry["tmdb_id"],
          Map.put(entry, "updated_at", System.os_time(:second))
        )

        IO.puts(:stderr, "playing in mpv: #{stream.filename}")

      {:error, reason} ->
        IO.puts(
          :stderr,
          "last source unavailable (#{unplayable_reason(reason)}) — searching fresh sources…"
        )

        continue_fallback(entry, rd_opts)
    end
  end

  # The remembered source died — re-run the normal search for the remembered
  # movie/episode so the user can pick a fresh one.
  defp continue_fallback(entry, rd_opts) do
    type = entry["type"]

    details =
      case fetch_details(%{type: type, id: entry["tmdb_id"]}) do
        {:ok, details} -> details
        {:error, reason} -> die("TMDB lookup failed: #{inspect(reason)}")
      end

    name = details["title"] || details["name"] || entry["title"]
    year = Tmdb.year(details["release_date"] || details["first_air_date"])

    ctx = %{
      type: type,
      tmdb_id: entry["tmdb_id"],
      title: name,
      season: entry["season"],
      episode: entry["episode"],
      poster_path: entry["poster_path"]
    }

    type
    |> title_sources(name, year, Tmdb.imdb_id(details), entry["season"], entry["episode"])
    |> probe_and_pick(rd_opts, ctx)
  end

  defp describe_resume(entry) do
    ep =
      cond do
        entry["season"] && entry["episode"] ->
          " · S#{pad2(entry["season"])}E#{pad2(entry["episode"])}"

        entry["episode"] ->
          " · Ep #{entry["episode"]}"

        true ->
          ""
      end

    "#{entry["title"]}#{ep} · last: #{String.slice(get_in(entry, ["source", "name"]) || "?", 0, 45)}"
  end

  # Let the user pick an item: fzf when available (arrows + fuzzy filter),
  # else a numbered prompt. Returns the chosen item, or nil on cancel.
  defp pick(items, describe, header) do
    if System.find_executable("fzf"),
      do: pick_fzf(items, describe, header),
      else: pick_number(items, describe, header)
  end

  defp pick_fzf(items, describe, header) do
    list =
      items
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {item, i} -> "#{i}\t#{describe.(item)}" end)

    path = Path.join(System.tmp_dir!(), "kino-fzf-#{System.os_time(:millisecond)}")
    File.write!(path, list)

    try do
      # fzf draws its UI on /dev/tty, reads the list from the redirected file,
      # and prints the chosen line on stdout — safe to run under System.cmd.
      case System.cmd(
             "sh",
             [
               "-c",
               ~s(fzf --delimiter='\t' --with-nth=2.. --no-multi --reverse --height=~60% --header="$2" < "$1"),
               "sh",
               path,
               header
             ]
           ) do
        {line, 0} ->
          {i, _} = line |> String.trim() |> Integer.parse()
          Enum.at(items, i)

        {_, _cancelled} ->
          nil
      end
    after
      File.rm(path)
    end
  end

  defp pick_number(items, describe, header) do
    items
    |> Enum.with_index(1)
    |> Enum.each(fn {item, i} ->
      IO.puts(String.pad_leading("#{i}", 3) <> ". " <> describe.(item))
    end)

    case IO.gets("#{header} (number, empty to quit) ") do
      :eof ->
        nil

      line ->
        case Integer.parse(String.trim(line)) do
          {n, ""} when n >= 1 and n <= length(items) -> Enum.at(items, n - 1)
          _ -> nil
        end
    end
  end

  defp describe(s) do
    prefix =
      case Map.get(s, :cached) do
        :library -> "★ "
        true -> "⚡ "
        _ -> ""
      end

    lang = Map.get(s, :lang)

    quality =
      [s.resolution, s.codec, s.audio, s.source, lang && "lang:#{lang}", Map.get(s, :provider)]
      |> Enum.reject(&(&1 in [nil, false]))
      |> Enum.join(" ")

    "#{prefix}#{s.name}  [#{s.size_human} · #{s.seeders} seeders" <>
      if(quality == "", do: "]", else: " · #{quality}]")
  end

  # ── resolve / play ────────────────────────────────────────────────

  defp resolve(argv) do
    {magnet, opts} = magnet_args(argv, "resolve")

    case RD.resolve_magnet(magnet, opts) do
      {:ok, stream} -> IO.puts(Jason.encode!(stream))
      {:error, reason} -> die_resolve(reason)
    end
  end

  defp play(argv) do
    {target, opts} = magnet_args(argv, "play")

    url =
      case target do
        "magnet:" <> _ ->
          case RD.resolve_magnet(target, opts) do
            {:ok, stream} -> stream.url
            {:error, reason} -> die_resolve(reason)
          end

        "http" <> _ ->
          target

        other ->
          die("play needs a magnet link or URL, got: #{String.slice(other, 0, 40)}")
      end

    Player.open(:mpv, url)
    IO.puts(Jason.encode!(%{playing: url}))
  end

  defp magnet_args(argv, cmd) do
    {opts, args, invalid} =
      OptionParser.parse(argv, strict: [season: :integer, episode: :integer])

    check_invalid(invalid)

    unless RD.configured?() do
      die("RD_TOKEN is not set — add it to #{Config.path()} or the environment")
    end

    case args do
      [target] -> {target, Keyword.take(opts, [:season, :episode])}
      _ -> die("#{cmd} needs exactly one magnet link (quote it!)")
    end
  end

  defp die_resolve({:not_cached, status, progress}) do
    die(%{error: "not cached on Real-Debrid", status: status, progress: progress})
  end

  defp die_resolve(reason), do: die("resolve failed: #{inspect(reason)}")

  # ── config ────────────────────────────────────────────────────────

  defp config do
    IO.puts(Jason.encode!(%{config_file: Config.path(), keys: Config.status()}))
  end

  # ── plumbing ──────────────────────────────────────────────────────

  defp check_invalid([]), do: :ok
  defp check_invalid(invalid), do: die("bad options: #{inspect(invalid)}")

  defp die(error) when is_map(error) do
    IO.puts(:stderr, Jason.encode!(error))
    System.halt(1)
  end

  defp die(message), do: die(%{error: message})

  defp usage(exit_code) do
    IO.puts(:stderr, """
    kino — search sources, resolve via your debrid account, play in mpv

    usage:
      kino watch "<title>"   [--raw] [--backend apibay|nyaa|anime] [--limit N]
      kino featured          browse what's trending on TMDB and pick something
      kino continue          resume what you were watching
      kino search "<query>"  [--backend apibay|nyaa|anime] [--limit N] [--json|--pretty]
      kino resolve <magnet>  [--season N] [--episode N]
      kino play <magnet|url> [--season N] [--episode N]
      kino config

    watch is interactive: pick the title (TMDB), for shows the season and
    episode, then a source — it resolves on your debrid account and plays
    in mpv. --raw skips TMDB and searches torrents by text directly.
    search prints a readable list at a terminal and JSON when piped.
    Config: #{Config.path()}
    """)

    System.halt(exit_code)
  end
end
