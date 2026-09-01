defmodule KinoTheatre.CLI do
  @moduledoc """
  The `kino` command-line interface.

  Emits JSON on stdout (one document per invocation) so frontends — the
  Omarchy overlay, scripts, a future TUI — can consume it. `--pretty` renders
  a human-readable listing instead.
  """

  alias KinoTheatre.{Config, Kitsu, Player, Providers, RD, Sources, Tmdb}

  @backends %{"apibay" => :apibay, "nyaa" => :nyaa, "anime" => :anime}

  def main(argv) do
    case argv do
      ["search" | rest] -> search(rest)
      ["watch" | rest] -> watch(rest)
      ["download" | rest] -> download(rest)
      ["featured" | _] -> featured()
      ["continue" | _] -> continue()
      ["resume" | _] -> resume()
      ["resolve" | rest] -> resolve(rest)
      ["play" | rest] -> play(rest)
      ["config" | _] -> config()
      ["setup" | _] -> setup()
      ["doctor" | _] -> doctor()
      ["update" | _] -> update()
      ["help" | _] -> usage(0)
      ["--help" | _] -> usage(0)
      [] -> if tty?(), do: main_menu(), else: usage(1)
      [other | _] -> die("unknown command: #{other} (try: kino help)")
    end
  end

  # ── main menu (bare `kino` at a terminal) ─────────────────────────

  # ASCII-art title over the main menu (figlet "Slant Relief", pre-rendered
  # and kerned, so no figlet install is needed). Slanted strokes lit in a
  # marquee red→gold gradient over a dim gray carved-relief ground.
  @banner [
    "__/\\\\\\________/\\\\\\_ __/\\\\\\\\\\\\\\\\\\\\\\_ __/\\\\\\\\\\_____/\\\\\\_ _______/\\\\\\\\\\______        ",
    " _\\/\\\\\\_____/\\\\\\//__ _\\/////\\\\\\///__ _\\/\\\\\\\\\\\\___\\/\\\\\\_ _____/\\\\\\///\\\\\\____       ",
    "  _\\/\\\\\\__/\\\\\\//_____ _____\\/\\\\\\_____ _\\/\\\\\\/\\\\\\__\\/\\\\\\_ ___/\\\\\\/__\\///\\\\\\__      ",
    "   _\\/\\\\\\\\\\\\//\\\\\\_____ _____\\/\\\\\\_____ _\\/\\\\\\//\\\\\\_\\/\\\\\\_ __/\\\\\\______\\//\\\\\\_     ",
    "    _\\/\\\\\\//_\\//\\\\\\____ _____\\/\\\\\\_____ _\\/\\\\\\\\//\\\\\\\\/\\\\\\_ _\\/\\\\\\_______\\/\\\\\\_    ",
    "     _\\/\\\\\\____\\//\\\\\\___ _____\\/\\\\\\_____ _\\/\\\\\\_\\//\\\\\\/\\\\\\_ _\\//\\\\\\______/\\\\\\__   ",
    "      _\\/\\\\\\_____\\//\\\\\\__ _____\\/\\\\\\_____ _\\/\\\\\\__\\//\\\\\\\\\\\\_ __\\///\\\\\\__/\\\\\\____  ",
    "       _\\/\\\\\\______\\//\\\\\\_ __/\\\\\\\\\\\\\\\\\\\\\\_ _\\/\\\\\\___\\//\\\\\\\\\\_ ____\\///\\\\\\\\\\/_____ ",
    "        _\\///________\\///__ _\\///////////__ _\\///_____\\/////__ ______\\/////_______"
  ]
  @banner_gradient [196, 202, 208, 214, 214, 220, 220, 226, 226]
  @banner_shadow 240

  defp print_banner do
    {_rows, cols} = tty_size()

    if cols >= 88 do
      IO.puts(:stderr, "")

      for {line, color} <- Enum.zip(@banner, @banner_gradient) do
        IO.puts(:stderr, "  " <> colorize_banner(line, color))
      end

      IO.puts(
        :stderr,
        IO.ANSI.format([:faint, :italic, "                               · your terminal cinema ·", :reset])
      )
    end
  end

  defp colorize_banner(line, color) do
    line
    |> String.graphemes()
    |> Enum.map_join(fn
      " " -> " "
      "_" -> IO.ANSI.color(@banner_shadow) <> "_"
      stroke -> IO.ANSI.color(color) <> stroke
    end)
    |> Kernel.<>(IO.ANSI.reset())
  end

  defp main_menu do
    # First run with no keys: go straight into the wizard instead of letting
    # every menu entry die with "RD_TOKEN is not set".
    unless Providers.any_configured?() and Tmdb.configured?() do
      IO.puts(:stderr, "\n  missing keys — let's set you up first")
      setup()
    end

    clear_screen()
    print_banner()
    IO.puts(:stderr, greeting())
    print_update_status()

    items =
      List.flatten([
        up_next_item(),
        {:continue, "▶ Continue — pick up where you left off"},
        {:featured, "★ Featured — trending movies, shows & anime"},
        {:search, "⌕ Search — find something by name"},
        {:settings, "⚙ Settings — toggles & preferences"}
      ])

    case pick(items, &menu_label/1, "↑↓ to move · enter to select · esc to quit") do
      nil -> System.halt(0)
      {:up_next, entry} -> play_next_episode(entry)
      {:resume_last, entry} -> continue_entry(entry)
      {:continue, _} -> continue()
      {:featured, _} -> featured()
      {:search, _} -> menu_search()
      {:settings, _} -> settings_menu()
    end
  end

  # ── settings (interactive toggles) ────────────────────────────────
  # Arrow through the settings, Enter toggles/cycles (or prompts, for text
  # values). Every change is written to the config file immediately and
  # takes effect for the rest of the session.

  @settings [
    {"KINO_AUTOPLAY", "⚡ Autoplay next episode", {:cycle, ["off", "on"]}},
    {"KINO_SKIP", "⏭ Intro/credits skipping", {:cycle, ["ask", "auto", "off"]}},
    {"KINO_POSTERS", "🖼 Poster previews", {:cycle, ["auto", "ascii", "ascii-bg", "off"]}},
    {"KINO_LANG", "🗣 Audio language preference", :text},
    {"KINO_SUBS", "💬 Subtitle language (off = none)", :text},
    {"KINO_DOWNLOAD_DIR", "📁 Download folder", :text},
    {"KINO_MPV_ARGS", "🎬 Extra mpv arguments", :text}
  ]

  defp settings_menu(selected \\ 0) do
    clear_screen()

    items =
      Enum.map(@settings, fn {key, label, kind} -> {:setting, key, label, kind} end) ++
        [{:keys, nil, "🔑 API keys — rerun the setup wizard", nil}]

    case pick(items, &describe_setting/1, "enter toggles or edits · esc goes back", nil, selected) do
      nil ->
        main_menu()

      {:keys, _, _, _} = item ->
        setup()
        settings_menu(Enum.find_index(items, &(&1 == item)) || 0)

      {:setting, key, label, kind} = item ->
        change_setting(key, label, kind)
        settings_menu(Enum.find_index(items, &(&1 == item)) || 0)
    end
  end

  defp describe_setting({:keys, _, label, _}), do: label

  defp describe_setting({:setting, key, label, _kind}),
    do: "#{String.pad_trailing(label, 34)}  [#{setting_value(key)}]"

  defp setting_value("KINO_AUTOPLAY"), do: if(Config.autoplay?(), do: "on", else: "off")
  defp setting_value("KINO_SKIP"), do: Config.skip()
  defp setting_value("KINO_POSTERS"), do: Config.posters()
  defp setting_value("KINO_LANG"), do: Config.lang()
  defp setting_value("KINO_SUBS"), do: Config.subs_lang() || "off"

  defp setting_value("KINO_DOWNLOAD_DIR"),
    do: Application.get_env(:kino_app, :download_dir) || Path.join(System.user_home!(), "Videos")

  defp setting_value("KINO_MPV_ARGS"),
    do: Application.get_env(:kino_app, :mpv_args) || "(none)"

  defp change_setting(key, _label, {:cycle, values}) do
    current = setting_value(key)
    index = Enum.find_index(values, &(&1 == current)) || 0
    next = Enum.at(values, rem(index + 1, length(values)))
    save_setting(key, next)
  end

  defp change_setting(key, label, :text) do
    case IO.gets("  #{label} [#{setting_value(key)}] — new value (enter keeps): ") do
      :eof ->
        :ok

      line ->
        case String.trim(line) do
          "" -> :ok
          value -> save_setting(key, value)
        end
    end
  end

  defp save_setting(key, value) do
    write_config_keys([{key, value}])
    # Env vars beat the file, so a shell-exported key won't budge — put the
    # new value straight into the app env so the change applies either way.
    Application.put_env(:kino_app, Map.fetch!(config_app_keys(), key), value)
  end

  defp config_app_keys do
    %{
      "KINO_AUTOPLAY" => :autoplay,
      "KINO_SKIP" => :skip,
      "KINO_POSTERS" => :posters,
      "KINO_LANG" => :lang,
      "KINO_SUBS" => :subs_lang,
      "KINO_DOWNLOAD_DIR" => :download_dir,
      "KINO_MPV_ARGS" => :mpv_args
    }
  end

  # The smart first row: if the most recent thing was an episode watched to
  # the end, offer its next episode; if it was left mid-way, offer to resume
  # it directly. Falls back to nothing (the plain menu) otherwise.
  defp up_next_item do
    case KinoTheatre.Resume.all() do
      [entry | _] ->
        ctx = entry_ctx(entry)

        cond do
          KinoTheatre.Position.finished?(ctx) and is_integer(entry["episode"]) ->
            [{:up_next, %{entry | "episode" => entry["episode"] + 1}}]

          KinoTheatre.Position.resume_at(ctx) != nil ->
            [{:resume_last, entry}]

          true ->
            []
        end

      _ ->
        []
    end
  end

  defp menu_label({:up_next, entry}),
    do: "⚡ Up Next — #{entry["title"]}#{entry_ep(entry)}"

  defp menu_label({:resume_last, entry}) do
    at =
      case KinoTheatre.Position.resume_at(entry_ctx(entry)) do
        nil -> ""
        time -> " · at #{time}"
      end

    "▶ Resume — #{entry["title"]}#{entry_ep(entry)}#{at}"
  end

  defp menu_label({_action, label}) when is_binary(label), do: label

  defp entry_ep(entry) do
    cond do
      entry["season"] && entry["episode"] -> " S#{pad2(entry["season"])}E#{pad2(entry["episode"])}"
      entry["episode"] -> " · Ep #{entry["episode"]}"
      true -> ""
    end
  end

  defp play_next_episode(entry) do
    IO.puts(:stderr, "#{entry["title"]}#{entry_ep(entry)} — finding sources…")
    play_entry(entry, rd_opts(entry["season"], entry["episode"]))
  end

  # Version line under the greeting. Capped at 2s and silent on any failure
  # so the menu never waits on GitHub; the result is cached between launches.
  defp print_update_status do
    task = Task.async(fn -> KinoTheatre.UpdateCheck.status() end)

    case Task.yield(task, 2000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:current, version}} ->
        IO.puts(:stderr, IO.ANSI.format([:faint, "  v#{version} — up to date\n", :reset]))

      {:ok, {:update, current, latest}} ->
        IO.puts(
          :stderr,
          IO.ANSI.format([
            :yellow,
            "  ⬆ v#{current} → v#{latest} available: ",
            :reset,
            "https://github.com/alexdont/kino/releases/latest\n"
          ])
        )

      _ ->
        :ok
    end
  end

  @weekdays ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
  @adjectives ~w(beautiful lovely wonderful cozy splendid fine quiet)

  defp greeting do
    user = System.get_env("USER") || System.get_env("USERNAME") || "you"
    {date, {hour, minute, _}} = :calendar.local_time()

    hello =
      cond do
        hour < 5 -> "Good Night"
        hour < 12 -> "Good Morning"
        hour < 17 -> "Good Afternoon"
        hour < 22 -> "Good Evening"
        true -> "Good Night"
      end

    {h12, ampm} = if hour >= 12, do: {hour - 12, "PM"}, else: {hour, "AM"}
    h12 = if h12 == 0, do: 12, else: h12
    day = Enum.at(@weekdays, :calendar.day_of_the_week(date) - 1)

    IO.ANSI.format([
      "\n  🍿 ",
      :bright,
      hello,
      :reset,
      ", ",
      :bright,
      :cyan,
      user,
      :reset,
      ".\n     It's ",
      :yellow,
      "#{h12}:#{pad2(minute)} #{ampm}",
      :reset,
      " on a ",
      :magenta,
      Enum.random(@adjectives),
      :reset,
      " ",
      :green,
      day,
      :reset,
      "!\n"
    ])
  end

  defp menu_search do
    case IO.gets("search for: ") do
      :eof ->
        System.halt(0)

      line ->
        case String.trim(line) do
          "" -> System.halt(0)
          query -> watch([query])
        end
    end
  end

  # True when stdout is a terminal (a human), false when piped (a frontend).
  defp tty?, do: IO.ANSI.enabled?()

  # Full-screen feel (mov-cli style): each menu screen replaces what came
  # before instead of stacking under the log noise. Wipes the visible screen
  # and the scrollback, then homes the cursor. Only ever called on a tty.
  defp clear_screen, do: IO.write(:stderr, "\e[2J\e[3J\e[H")

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

  defp watch(argv), do: run_watch(argv)

  # Same flow as watch, but the chosen stream is saved to disk instead of
  # played. The mode is read at the single point where playback happens
  # (finish_play/4), so the whole title/source pipeline is shared.
  defp download(argv) do
    Process.put(:kino_mode, :download)
    run_watch(argv)
  end

  defp run_watch(argv) do
    {opts, query} = watch_args(argv)

    unless Providers.any_configured?() do
      die("no debrid provider configured (RD_TOKEN or TORBOX_API_KEY) — run: kino setup")
    end

    if opts[:auto], do: Process.put(:kino_auto, true)
    if opts[:binge], do: Process.put(:kino_binge, true)

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
        strict: [backend: :string, limit: :integer, raw: :boolean, auto: :boolean, binge: :boolean]
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
        {:error, reason} -> die(tmdb_error(reason, "lookup"))
      end

    if anime?(details) do
      play_anime(title, details)
    else
      play_standard(title, details)
    end
  end

  # The one play-context builder — every play path goes through this (or
  # entry_ctx/1 for resume entries) so the shape can't drift between them.
  defp build_ctx(type, tmdb_id, title, opts) do
    %{
      type: type,
      tmdb_id: tmdb_id,
      title: title,
      season: opts[:season],
      episode: opts[:episode],
      poster_path: opts[:poster_path],
      anime: opts[:anime] || false,
      search_title: opts[:search_title]
    }
  end

  defp entry_ctx(entry) do
    build_ctx(entry["type"], entry["tmdb_id"], entry["title"],
      season: entry["season"],
      episode: entry["episode"],
      poster_path: entry["poster_path"],
      anime: entry["anime"] || false,
      search_title: entry["search_title"]
    )
  end

  defp play_standard(title, details) do
    imdb = Tmdb.imdb_id(details)

    {season, episode} =
      case title.type do
        "movie" -> {nil, nil}
        "tv" -> pick_episode(details)
      end

    ctx =
      build_ctx(title.type, title.id, title.title,
        season: season,
        episode: episode,
        poster_path: details["poster_path"]
      )

    title.type
    |> title_sources(title.title, title.year, imdb, season, episode)
    |> probe_and_pick(rd_opts(season, episode), ctx)
  end

  # ── anime ─────────────────────────────────────────────────────────
  # Anime lives on different trackers (Nyaa/AnimeTosho), uses absolute episode
  # numbers (no seasons), and matches best by AniDB id — so route it through
  # Kitsu instead of the live-action season/episode flow.

  defp anime?(%{"original_language" => "ja", "genres" => genres}) when is_list(genres),
    do: Enum.any?(genres, &(&1["id"] == 16))

  defp anime?(_details), do: false

  defp play_anime(title, details) do
    IO.puts(:stderr, "anime — matching on Kitsu for episode list + AniDB id…")
    kitsu = kitsu_pick(title.title)
    search_title = (kitsu.anime && kitsu.anime.title) || title.title

    case {title.type, kitsu.episodes} do
      {"movie", _} ->
        ctx = anime_ctx(title, details, nil, search_title)
        q = Sources.anime_movie_query(search_title)

        case Sources.search(q, backend: :anime) do
          {:ok, sources} -> with_library(q, sources) |> probe_and_pick([], ctx)
          {:error, reason} -> die("anime source search failed: #{inspect(reason)}")
        end

      {"tv", []} ->
        # Not on Kitsu (or no episodes listed) — the live-action flow still
        # works via Torrentio's IMDb-id lookup.
        IO.puts(:stderr, "not matched on Kitsu — falling back to the standard flow")
        play_standard(title, details)

      {"tv", episodes} ->
        describe = fn ep ->
          watched_mark(%{type: "tv", tmdb_id: title.id, season: nil, episode: ep.number}) <>
            describe_anime_episode(ep)
        end

        episode = pick(episodes, describe, "which episode?") || System.halt(0)
        n = episode.number
        sources = anime_episode_sources(search_title, n, kitsu.anidb)
        q = Sources.anime_episode_query(search_title, n)

        with_library(q, sources)
        |> probe_and_pick([episode: n], anime_ctx(title, details, n, search_title))
    end
  end

  defp anime_ctx(title, details, episode, search_title) do
    build_ctx(title.type, title.id, title.title,
      episode: episode,
      poster_path: details["poster_path"],
      anime: true,
      search_title: search_title
    )
  end

  # Anime seasons live as separate Kitsu entries ("Attack on Titan",
  # "… Season 2", "… Final Season") — so the entry picker IS the season
  # selector. Auto-picks when there's only one match.
  defp kitsu_pick(name) do
    case Kitsu.search(name) do
      {:ok, []} ->
        %{anime: nil, episodes: [], anidb: nil}

      {:ok, [only]} ->
        kitsu_selected(only)

      {:ok, results} ->
        # Chronological, not by title — "Part 2"/"Final Season" naming makes
        # alphabetical order useless; year is the real season order. Stable
        # sort keeps same-year entries (S1 + its Part 2) in sane order.
        results = Enum.sort_by(results, &(&1.year || "9999"))

        case pick(results, &describe_kitsu/1, "which season/entry?", & &1.poster) do
          nil -> System.halt(0)
          anime -> kitsu_selected(anime)
        end

      _ ->
        %{anime: nil, episodes: [], anidb: nil}
    end
  end

  # Non-interactive variant for resume/next-episode flows: the stored
  # search_title re-matches its own entry first, so no picker needed.
  defp kitsu_lookup(name) do
    case Kitsu.search(name) do
      {:ok, [anime | _]} -> kitsu_selected(anime)
      _ -> %{anime: nil, episodes: [], anidb: nil}
    end
  end

  defp kitsu_selected(anime) do
    # AniList-sourced entries (Kitsu down/slow) have no Kitsu id — no AniDB
    # mapping for them; tracker search falls back to the release title.
    anidb =
      with id when not is_nil(id) <- anime.id,
           {:ok, mapped} <- Kitsu.anidb_id(id) do
        mapped
      else
        _ -> nil
      end

    %{anime: anime, episodes: kitsu_episode_list(anime), anidb: anidb}
  end

  defp describe_kitsu(a) do
    eps = if a.episode_count, do: " · #{a.episode_count} eps", else: ""
    "#{a.title} (#{a.year || "?"}) · #{a.subtype}#{eps}"
  end

  defp kitsu_episode_list(%{episode_count: count}) when is_integer(count) and count > 0,
    do: Enum.map(1..count, &%{number: &1, name: nil})

  # No count and no Kitsu id to fetch an episode list from (AniList entry).
  defp kitsu_episode_list(%{id: nil}), do: []

  defp kitsu_episode_list(anime) do
    {:ok, episodes} = Kitsu.episodes(anime.id)
    episodes
  end

  # Returns episode-specific releases first, then the show's batch packs
  # (either can contain the episode; RD's file picker extracts it).
  defp anime_episode_sources(search_title, episode, anidb) do
    case Sources.anime_episode_search(search_title, episode, anidb_id: anidb) do
      {:ok, sources, _scope} -> sources
      {:error, reason} -> die("anime source search failed: #{inspect(reason)}")
    end
  end

  defp describe_anime_episode(ep) do
    name = Map.get(ep, :name)
    "E#{pad2(ep.number)}#{if name in [nil, ""], do: "", else: " #{name}"}"
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
    unless Providers.any_configured?() do
      die("no debrid provider configured (RD_TOKEN or TORBOX_API_KEY) — run: kino setup")
    end

    unless Tmdb.configured?() do
      die("featured needs TMDB_API_KEY — add it to #{Config.path()} or the environment")
    end

    type =
      case pick(["movies", "shows", "anime"], &String.capitalize/1, "what are you in the mood for?") do
        "movies" -> "movie"
        "shows" -> "tv"
        "anime" -> :anime
        nil -> System.halt(0)
      end

    title = pick_featured(type, 1, []) || System.halt(0)
    play_title(title)
  end

  defp pick_featured(type, page, acc) do
    {results, more?} =
      case featured_page(type, page) do
        {:ok, results, more?} -> {results, more?}
        {:error, reason} -> die(tmdb_error(reason, "trending lookup"))
      end

    titles = Enum.uniq_by(acc ++ results, &{&1.type, &1.id})
    items = if more?, do: titles ++ [:more], else: titles

    case pick(items, &describe_title_item/1, featured_header(type), &title_poster/1) do
      :more -> pick_featured(type, page + 1, titles)
      other -> other
    end
  end

  defp featured_page(:anime, page), do: Tmdb.discover_anime(page)
  defp featured_page(type, page), do: Tmdb.trending(type, page)

  defp featured_header(:anime), do: "popular anime"
  defp featured_header("movie"), do: "trending movies this week"
  defp featured_header("tv"), do: "trending shows this week"

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
          {:error, reason} -> die(tmdb_error(reason, "search"))
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

        case pick(items, &describe_title_item/1, header, &title_poster/1) do
          :more -> pick_title(q, year, page + 1, titles)
          other -> other
        end
    end
  end

  defp title_poster(:more), do: nil
  defp title_poster(title), do: title.poster

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
        {:error, reason} -> die(tmdb_error(reason, "season lookup"))
      end

    describe = fn e ->
      mark =
        watched_mark(%{
          type: "tv",
          tmdb_id: details["id"],
          season: season_number,
          episode: e["episode_number"]
        })

      mark <> describe_episode(e)
    end

    episode = pick(episodes, describe, "which episode?") || System.halt(0)
    {season_number, episode["episode_number"]}
  end

  defp watched_mark(ctx), do: if(KinoTheatre.Position.finished?(ctx), do: "✓ ", else: "")

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
    rating = if t.vote && t.vote > 0, do: " · ★ #{Float.round(t.vote * 1.0, 1)}"
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

  defp probe_and_pick(sources, rd_opts, ctx, playable_so_far \\ [], sub_task \\ nil)

  defp probe_and_pick([], _rd_opts, _ctx, [], _sub_task) do
    die("no playable sources — try another title or release")
  end

  defp probe_and_pick(sources, rd_opts, ctx, playable_so_far, sub_task) do
    if Process.get(:kino_auto) do
      auto_play(sources, rd_opts, ctx)
    else
      do_probe_and_pick(sources, rd_opts, ctx, playable_so_far, sub_task)
    end
  end

  # --auto: no source picker — walk the ranked list and play the first
  # source that actually resolves (RD.resolve_best stops at the first hit,
  # so nothing beyond it is probed).
  defp auto_play(sources, rd_opts, ctx) do
    sub_task = if Process.get(:kino_mode, :play) == :play, do: start_subtitle_task(ctx)
    IO.puts(:stderr, "auto — trying sources best-first…")

    notify = fn
      {:trying, name} ->
        IO.puts(:stderr, "  → #{String.slice(name, 0, 70)}")

      {:skipped, name, reason} ->
        IO.puts(:stderr, "  ✗ #{String.slice(name, 0, 55)} — #{unplayable_reason(reason)}")
    end

    case Providers.resolve_best(sources, Keyword.put(rd_opts, :notify, notify)) do
      {:ok, stream, source, _skipped} ->
        finish_play(ctx, source, stream, sub_task)

      {:error, {:all_failed, _skipped}} ->
        if sub_task, do: Task.shutdown(sub_task, :brutal_kill)
        die("no playable sources — try again without --auto to see the full list")
    end
  end

  defp do_probe_and_pick(sources, rd_opts, ctx, playable_so_far, sub_task) do
    # Fetch subtitles in the background while sources are being probed, so
    # the network round-trips overlap instead of delaying the mpv launch.
    sub_task = sub_task || start_subtitle_task(ctx)
    # Quality-diverse page: some of every resolution tier gets probed up
    # front, so picking 1080p never requires wading through all the 4Ks.
    {page, rest} = Sources.probe_page(sources, @probe_page)

    IO.puts(
      :stderr,
      "checking #{length(page)} sources (#{length(rest)} more unchecked)…"
    )

    parent = self()

    notify = fn {:result, index, source, result} ->
      case result do
        {:ok, stream} ->
          IO.puts(:stderr, "  ✓ #{source.name}#{provider_tag(stream)}")
          send(parent, {:playable, index, source, stream})

        {:error, reason} ->
          IO.puts(:stderr, "  ✗ #{source.name} — #{unplayable_reason(reason)}")
      end
    end

    Providers.probe_sources(Enum.with_index(page), Keyword.put(rd_opts, :notify, notify))
    playable = playable_so_far ++ collect_playable()

    case {playable, rest} do
      {[], []} ->
        die("no playable sources — try another title or release")

      {[], rest} ->
        IO.puts(:stderr, "none playable yet — checking the next page…")
        probe_and_pick(rest, rd_opts, ctx, [], sub_task)

      {playable, rest} ->
        items = if rest == [], do: playable, else: playable ++ [:more]

        case pick(items, &describe_playable/1, "which source? (all checked + playable)") do
          nil ->
            System.halt(0)

          :more ->
            probe_and_pick(rest, rd_opts, ctx, playable, sub_task)

          {source, stream} ->
            finish_play(ctx, source, stream, sub_task)
        end
    end
  end

  defp finish_play(ctx, source, stream, sub_task) do
    case Process.get(:kino_mode, :play) do
      :download ->
        if sub_task, do: Task.shutdown(sub_task, :brutal_kill)
        download_stream(stream)

      :play ->
        Player.open(
          :mpv,
          stream.url,
          await_subtitles(sub_task) ++ position_args(ctx, stream.filename) ++ KinoTheatre.Skip.script_args()
        )

        save_resume(ctx, source)
        IO.puts(:stderr, "playing in mpv: #{stream.filename}")

        binge? = Process.get(:kino_binge) || Config.autoplay?()

        if binge? and ctx && is_integer(ctx.episode),
          do: binge_wait(ctx),
          else: post_play_menu(ctx, stream)
    end
  end

  # ── binge mode (auto-next on episode end) ─────────────────────────
  # kino stays alive watching the position file the Lua tracker writes:
  # "done" (mpv hit eof) → countdown → next episode, auto-picked. A stale
  # file (no save for 25s while the tracker saves every 5s) means the user
  # closed mpv mid-episode — binge ends quietly.

  defp binge_wait(ctx) do
    IO.puts(
      :stderr,
      IO.ANSI.format([
        :faint,
        "binge mode: next episode starts when this one ends (Ctrl-C quits kino, mpv keeps playing)",
        :reset
      ])
    )

    watch_for_eof(ctx, System.os_time(:second))
  end

  defp watch_for_eof(ctx, started_at) do
    Process.sleep(3_000)

    cond do
      KinoTheatre.Position.finished?(ctx) ->
        countdown_next(ctx)

      stale?(ctx, started_at) ->
        IO.puts(:stderr, "mpv closed mid-episode — leaving binge mode")

      true ->
        watch_for_eof(ctx, started_at)
    end
  end

  # No position save for 25s (tracker writes every 5s) = mpv is gone. The
  # started_at grace period covers mpv's startup before the first save.
  defp stale?(ctx, started_at) do
    now = System.os_time(:second)

    case KinoTheatre.Position.last_saved_at(ctx) do
      nil -> now - started_at > 60
      mtime -> now - mtime > 25
    end
  end

  defp countdown_next(ctx) do
    next = %{ctx | episode: ctx.episode + 1}
    IO.puts(:stderr, "")

    for n <- 10..1//-1 do
      IO.write(:stderr, "\r  ⚡ next: #{playing_desc(next)} in #{n}s… (Ctrl-C stops) ")
      Process.sleep(1_000)
    end

    IO.puts(:stderr, "")
    Process.put(:kino_auto, true)
    play_adjacent(ctx, 1)
  end

  # ── post-play controls (mov-cli style) ────────────────────────────
  # mpv runs detached, so instead of exiting we stay on a control screen
  # while the video plays: chain into the next episode, replay, go back to
  # picking, or quit. Esc/quit leaves mpv running.

  defp post_play_menu(nil, _stream), do: :ok

  defp post_play_menu(ctx, stream) do
    if tty?() do
      clear_screen()

      IO.puts(
        :stderr,
        IO.ANSI.format([
          "\n  ▶ ",
          :bright,
          "Now Playing",
          :reset,
          ": ",
          :cyan,
          playing_desc(ctx),
          :reset,
          "\n"
        ])
      )

      # The launch-time stinger alert gets wiped by this screen — repeat it
      # here, where it stays visible for the whole watch. Cache-warm by the
      # pre-launch task, so this never waits on TMDB.
      case KinoTheatre.Skip.stinger_parts(ctx) do
        [] ->
          :ok

        parts ->
          IO.puts(
            :stderr,
            IO.ANSI.format([
              :yellow,
              "  🎬 #{KinoTheatre.Skip.stinger_label(parts)}",
              :reset,
              :faint,
              " — worth staying through the credits\n",
              :reset
            ])
          )
      end

      episodic? = is_integer(ctx.episode)

      items =
        List.flatten([
          if(episodic?, do: [{:next, "⏭  next episode"}], else: []),
          if(episodic?, do: [{:binge, "⚡  autoplay — chain next episodes"}], else: []),
          {:replay, "↻  replay"},
          {:imdb, "★  rate on IMDb — open in browser"},
          {:switch, "⇄  try another source"},
          if(episodic? and ctx.episode > 1, do: [{:previous, "⏮  previous episode"}], else: []),
          if(episodic?,
            do: [{:select, "☰  episodes — choose another"}],
            else: [{:select, "⌕  search — find something else"}]
          ),
          {:quit, "✕  quit"}
        ])

      case pick(items, &elem(&1, 1), "what next?") do
        {:next, _} -> play_adjacent(ctx, 1)
        {:binge, _} ->
          Process.put(:kino_binge, true)
          binge_wait(ctx)
        {:replay, _} -> replay(ctx, stream)
        {:switch, _} -> switch_source(ctx)
        {:previous, _} -> play_adjacent(ctx, -1)
        {:select, _} -> reselect(ctx)
        {:imdb, _} ->
          open_imdb(ctx)
          post_play_menu(ctx, stream)
        _ -> System.halt(0)
      end
    end
  end

  # Same URL again; position args resume from wherever the tracker last
  # saved, so "replay" doubles as "reopen where I was" after closing mpv.
  defp replay(ctx, stream) do
    args =
      subtitle_args(ctx) ++
        KinoTheatre.Skip.window_args(ctx) ++
        KinoTheatre.Skip.stinger_args(ctx) ++
        position_args(ctx, stream.filename) ++ KinoTheatre.Skip.script_args()

    Player.open(:mpv, stream.url, args)
    IO.puts(:stderr, "playing in mpv: #{stream.filename}")
    post_play_menu(ctx, stream)
  end

  # Next/previous episode: rebuild the play context with episode ± 1 and
  # rerun the full source flow (which respects --auto and re-enters this
  # menu after launch — that's the binge loop).
  defp play_adjacent(ctx, delta) do
    ctx = %{ctx | episode: ctx.episode + delta}
    clear_screen()
    IO.puts(:stderr, "#{playing_desc(ctx)} — finding sources…")
    play_entry(ctx_entry(ctx), rd_opts(ctx.season, ctx.episode))
  end

  # Bad source (broken file, wrong audio, stutters): re-run the source flow
  # for the same title/episode and pick a different release. Position memory
  # is keyed by title, so the new source resumes at the same second — and
  # track memory correctly resets (ids don't carry across releases).
  defp switch_source(ctx) do
    clear_screen()
    IO.puts(:stderr, "#{playing_desc(ctx)} — finding sources (close the old mpv yourself)…")
    play_entry(ctx_entry(ctx), rd_opts(ctx.season, ctx.episode))
  end

  defp reselect(ctx) do
    clear_screen()

    if is_integer(ctx.episode) do
      play_title(%{type: ctx.type, id: ctx.tmdb_id, title: ctx.title, year: nil})
    else
      menu_search()
    end
  end

  # Open the title's IMDb page in the browser (the user rates and logs
  # watched titles there). The IMDb id comes from TMDB's external ids; with
  # no match, fall back to an IMDb search for the title.
  defp open_imdb(ctx) do
    url =
      with {:ok, details} <- fetch_details(%{type: ctx.type, id: ctx.tmdb_id}),
           imdb when is_binary(imdb) <- Tmdb.imdb_id(details) do
        "https://www.imdb.com/title/#{imdb}/"
      else
        _ -> "https://www.imdb.com/find/?q=#{URI.encode_www_form(ctx.title || "")}"
      end

    browser_open(url)
    IO.puts(:stderr, "opened in browser: #{url}")
  end

  # Detached, like the mpv launch — the browser must outlive kino.
  defp browser_open(url) do
    case System.find_executable("xdg-open") || System.find_executable("open") do
      nil -> IO.puts(:stderr, "no browser opener found — visit: #{url}")
      opener -> System.cmd("sh", ["-c", ~s("$@" >/dev/null 2>&1 &), "sh", opener, url])
    end
  end

  defp playing_desc(ctx) do
    cond do
      ctx.season && ctx.episode -> "#{ctx.title} S#{pad2(ctx.season)}E#{pad2(ctx.episode)}"
      ctx.episode -> "#{ctx.title} · Ep #{ctx.episode}"
      true -> ctx.title
    end
  end

  # RD hands us a plain HTTPS URL, so downloading is just curl with resume
  # support; its progress bar renders on stderr.
  defp download_stream(stream) do
    dir =
      Application.get_env(:kino_app, :download_dir) ||
        Path.join(System.user_home!(), "Videos")

    File.mkdir_p!(dir)
    dest = Path.join(dir, stream.filename)

    size =
      case stream.filesize do
        n when is_integer(n) and n > 0 -> " (#{Float.round(n / 1.0e9, 2)} GB)"
        _ -> ""
      end

    IO.puts(:stderr, "downloading #{stream.filename}#{size} → #{dest}")

    case System.cmd(
           "curl",
           ["-L", "--fail", "--retry", "3", "-C", "-", "--progress-bar", "-o", dest, stream.url]
         ) do
      {_, 0} ->
        IO.puts(:stderr, "✔ saved to #{dest}")
        IO.puts(Jason.encode!(%{downloaded: dest}))

      {_, code} ->
        die("download failed (curl exit #{code}) — partial file kept, rerun to resume")
    end
  end

  # Position tracking + exact resume: mpv gets a tiny Lua script that saves
  # the playback position every 5s (crash-safe), keyed by title+episode so
  # switching sources resumes from the same spot.
  defp position_args(ctx, filename \\ nil)
  defp position_args(nil, _filename), do: []

  defp position_args(ctx, filename) do
    case KinoTheatre.Position.mpv_args(ctx, filename) do
      {args, nil} ->
        args

      {args, resume_at} ->
        IO.puts(:stderr, "resuming from #{resume_at}")
        args
    end
  end

  # Subtitles and AniSkip windows both need network round-trips — fetch them
  # together in the background while sources are probed / RD resolves.
  defp start_subtitle_task(nil), do: nil

  defp start_subtitle_task(ctx),
    do:
      Task.async(fn ->
        subtitle_args(ctx) ++
          KinoTheatre.Skip.window_args(ctx) ++ KinoTheatre.Skip.stinger_args(ctx)
      end)

  defp await_subtitles(nil), do: []

  defp await_subtitles(task) do
    case Task.yield(task, 45_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, args} ->
        args

      _ ->
        IO.puts(:stderr, "subtitle fetch timed out — playing without")
        []
    end
  end

  # Fetch an external subtitle when a provider is configured (Jimaku for
  # anime, OpenSubtitles otherwise) and hand it to mpv. Silent when no
  # provider is set up — mpv still offers the stream's embedded tracks.
  defp subtitle_args(ctx) do
    case Config.subs_lang() do
      nil ->
        []

      lang ->
        case KinoTheatre.SubtitleFetch.fetch(ctx, lang) do
          {:ok, path, label} ->
            IO.puts(:stderr, "subtitles: #{label}")
            ["--sub-file=#{path}"]

          {:error, :no_provider} ->
            if Config.subs_explicit?() do
              IO.puts(:stderr, "KINO_SUBS is set but no subtitle provider is configured for " <>
                "this content (OPENSUBTITLES_* — or JIMAKU_API_KEY for anime)")
            end

            []

          {:error, reason} ->
            IO.puts(:stderr, "no external subtitles (#{sub_reason(reason)}) — embedded tracks still available")
            []
        end
    end
  end

  defp tmdb_error({:tmdb, 401, _}, _op),
    do: "TMDB rejected the key (401) — check TMDB_API_KEY in #{Config.path()}"

  defp tmdb_error(reason, op), do: "TMDB #{op} failed: #{inspect(reason)}"

  defp sub_reason(:not_found), do: "none found for this title"
  defp sub_reason(:no_file), do: "no file for this episode/language"
  defp sub_reason(:opensubtitles_needs_login), do: "OpenSubtitles download needs username+password"
  defp sub_reason({:exception, message}), do: "subtitle fetch crashed: #{message}"
  defp sub_reason(reason), do: inspect(reason)

  # Remember what was played (episode + exact source) so `kino continue`
  # can jump straight back without re-hunting sources.
  defp save_resume(nil, _source), do: :ok

  defp save_resume(ctx, source) do
    entry =
      ctx_entry(ctx)
      |> Map.merge(%{
        "source" => %{"name" => source.name, "magnet" => source.magnet, "hash" => source.hash},
        "updated_at" => System.os_time(:second)
      })

    KinoTheatre.Resume.put(ctx.type, ctx.tmdb_id, entry)
  end

  # A ctx as a resume-style entry map — the inverse of entry_ctx/1, so the
  # post-play menu can feed play contexts back into the entry-based flow.
  defp ctx_entry(ctx) do
    %{
      "type" => ctx.type,
      "tmdb_id" => ctx.tmdb_id,
      "season" => ctx.season,
      "episode" => ctx.episode,
      "title" => ctx.title,
      "poster_path" => ctx[:poster_path],
      "anime" => ctx[:anime] || false,
      "search_title" => ctx[:search_title]
    }
  end

  defp describe_playable(:more), do: "⋯ check more sources"
  defp describe_playable({source, stream}), do: describe(source) <> provider_tag(stream)

  defp provider_tag(%{provider: :torbox}), do: "  ⚡TB"
  defp provider_tag(_stream), do: ""

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
  defp unplayable_reason(:infringing), do: "infringing — taken down"
  defp unplayable_reason({:rd, 451, _}), do: "infringing — taken down"
  defp unplayable_reason(:no_video_files), do: "no video file in the torrent"
  defp unplayable_reason(:magnet_error), do: "bad magnet link"
  defp unplayable_reason(:no_seeders), do: "dead torrent — no seeders"

  defp unplayable_reason({:torrent_status, "error"}),
    do: "RD couldn't download it (usually no seeders)"

  defp unplayable_reason({:torrent_status, status}), do: "RD download failed (#{status})"
  defp unplayable_reason({:download_timeout, pct}), do: "RD download timed out at #{pct}%"
  defp unplayable_reason({:rd, 401, _}), do: rd_auth_error()
  defp unplayable_reason({:rd, 401}), do: rd_auth_error()
  defp unplayable_reason({:rd, status, _}), do: "Real-Debrid error #{status}"
  defp unplayable_reason({:rd, status}), do: "Real-Debrid error #{status}"
  defp unplayable_reason({:torbox, status, detail}), do: "TorBox: #{detail} (#{status})"
  defp unplayable_reason({:torbox, status}), do: "TorBox error #{status}"

  defp unplayable_reason(:no_provider_configured),
    do: "no debrid provider configured — run: kino setup"
  defp unplayable_reason(reason), do: inspect(reason)

  defp rd_auth_error,
    do: "Real-Debrid rejected the token (401) — check RD_TOKEN in #{Config.path()}"

  # ── continue watching ─────────────────────────────────────────────

  defp continue do
    unless Providers.any_configured?() do
      die("no debrid provider configured (RD_TOKEN or TORBOX_API_KEY) — run: kino setup")
    end

    entries = KinoTheatre.Resume.all()
    if entries == [], do: die("nothing to continue — play something with kino watch first")

    entry = pick(entries, &describe_resume/1, "continue watching") || System.halt(0)
    continue_entry(entry)
  end

  # `kino resume`: straight back into the most recent thing — no picker.
  defp resume do
    unless Providers.any_configured?() do
      die("no debrid provider configured (RD_TOKEN or TORBOX_API_KEY) — run: kino setup")
    end

    case KinoTheatre.Resume.all() do
      [] ->
        die("nothing to resume — play something with kino watch first")

      [entry | _] ->
        at =
          case KinoTheatre.Position.resume_at(entry_ctx(entry)) do
            nil -> ""
            time -> " · at #{time}"
          end

        IO.puts(:stderr, "resuming #{entry["title"]}#{entry_ep(entry)}#{at}")
        continue_entry(entry)
    end
  end

  defp continue_entry(entry) do
    rd_opts = rd_opts(entry["season"], entry["episode"])
    source = entry["source"]

    IO.puts(:stderr, "trying the source you last played: #{source["name"]}")

    # Subtitles fetch in the background while RD resolves.
    ctx = entry_ctx(entry)
    sub_task = start_subtitle_task(ctx)

    case Providers.resolve_magnet(source["magnet"], rd_opts) do
      {:ok, stream} ->
        Player.open(
          :mpv,
          stream.url,
          await_subtitles(sub_task) ++ position_args(ctx, stream.filename) ++ KinoTheatre.Skip.script_args()
        )
        KinoTheatre.Resume.put(
          entry["type"],
          entry["tmdb_id"],
          Map.put(entry, "updated_at", System.os_time(:second))
        )

        IO.puts(:stderr, "playing in mpv: #{stream.filename}")
        post_play_menu(ctx, stream)

      {:error, reason} ->
        Task.shutdown(sub_task, :brutal_kill)

        IO.puts(
          :stderr,
          "last source unavailable (#{unplayable_reason(reason)}) — searching fresh sources…"
        )

        play_entry(entry, rd_opts)
    end
  end

  # Run the full source flow for an entry map (a resume entry, or a ctx via
  # ctx_entry/1): fetch details, route anime vs standard, probe, pick, play.
  defp play_entry(entry, rd_opts) do
    type = entry["type"]

    unless Tmdb.configured?() do
      die("searching for sources needs TMDB_API_KEY — " <>
        "add it to #{Config.path()} or the environment")
    end

    details =
      case fetch_details(%{type: type, id: entry["tmdb_id"]}) do
        {:ok, details} -> details
        {:error, reason} -> die(tmdb_error(reason, "lookup"))
      end

    name = details["title"] || details["name"] || entry["title"]
    year = Tmdb.year(details["release_date"] || details["first_air_date"])
    ctx = entry_ctx(entry) |> Map.put(:title, name)

    cond do
      anime?(details) and type == "tv" and is_integer(entry["episode"]) ->
        # The stored search_title is the exact Kitsu entry (= season) the
        # user was watching — re-matching with it skips the season picker.
        kitsu = kitsu_lookup(entry["search_title"] || name)
        search_title = (kitsu.anime && kitsu.anime.title) || name
        n = entry["episode"]
        ctx = Map.merge(ctx, %{anime: true, search_title: search_title})

        Sources.anime_episode_query(search_title, n)
        |> with_library(anime_episode_sources(search_title, n, kitsu.anidb))
        |> probe_and_pick([episode: n], ctx)

      anime?(details) and type == "movie" ->
        kitsu = kitsu_lookup(entry["search_title"] || name)
        search_title = (kitsu.anime && kitsu.anime.title) || name
        ctx = Map.merge(ctx, %{anime: true, search_title: search_title})
        q = Sources.anime_movie_query(search_title)

        case Sources.search(q, backend: :anime) do
          {:ok, sources} -> with_library(q, sources) |> probe_and_pick([], ctx)
          {:error, reason} -> die("anime source search failed: #{inspect(reason)}")
        end

      true ->
        type
        |> title_sources(name, year, Tmdb.imdb_id(details), entry["season"], entry["episode"])
        |> probe_and_pick(rd_opts, ctx)
    end
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

    at =
      case KinoTheatre.Position.resume_at(entry_ctx(entry)) do
        nil -> ""
        time -> " · at #{time}"
      end

    "#{entry["title"]}#{ep}#{at} · last: #{String.slice(get_in(entry, ["source", "name"]) || "?", 0, 45)}"
  end

  # Let the user pick an item: fzf when available (arrows + fuzzy filter),
  # else a numbered prompt. Returns the chosen item, or nil on cancel.
  # `preview` maps an item to an image URL (or nil) — rendered next to the
  # list via chafa when both chafa and a URL are available.
  # `initial` restores the cursor to that item index — used by menus that
  # re-render after an action (settings), so the cursor doesn't jump home.
  defp pick(items, describe, header, preview \\ nil, initial \\ nil) do
    if System.find_executable("fzf"),
      do: pick_fzf(items, describe, header, preview, initial),
      else: pick_number(items, describe, header)
  end

  # Runs inside fzf's preview pane: {2} is the poster URL column. Downloads
  # once into a tmp cache, renders with chafa sized to the pane.
  @poster_preview ~S"""
  url={2}; if [ "$url" = "-" ]; then echo; else d="${TMPDIR:-/tmp}/kino-posters"; mkdir -p "$d"; f="$d/$(printf %s "$url" | md5sum | cut -c1-16)"; [ -s "$f" ] || curl -sL "$url" -o "$f" 2>/dev/null; chafa CHAFA_OPTS --size=${FZF_PREVIEW_COLUMNS}x${FZF_PREVIEW_LINES} "$f" 2>/dev/null || echo; fi
  """ |> String.trim()

  @poster_cache_max_age_s 30 * 24 * 3600

  defp prune_posters do
    dir = Path.join(System.tmp_dir!(), "kino-posters")
    cutoff = System.os_time(:second) - @poster_cache_max_age_s

    case File.ls(dir) do
      {:ok, names} ->
        for name <- names,
            path = Path.join(dir, name),
            {:ok, %{mtime: mtime}} <- [File.stat(path, time: :posix)],
            mtime < cutoff do
          File.rm(path)
        end

        :ok

      _ ->
        :ok
    end
  end

  # Inside fzf's preview pipe chafa can't auto-detect terminal graphics, so
  # it silently degrades to colored block characters. Force the pixel
  # protocol by terminal identity instead; block symbols only as last resort.
  # KINO_POSTERS=ascii swaps the whole thing for colored ASCII art —
  # foreground glyphs only; =ascii-bg additionally paints cell backgrounds.
  defp poster_preview_script do
    term = System.get_env("TERM") || ""
    program = System.get_env("TERM_PROGRAM") || ""

    chafa_opts =
      cond do
        Config.posters() == "ascii" -> "-f symbols -c full --symbols ascii --fg-only"
        Config.posters() == "ascii-bg" -> "-f symbols -c full --symbols ascii"
        String.contains?(term, "foot") -> "-f sixels"
        String.contains?(term, "kitty") or String.contains?(term, "ghostty") -> "-f kitty"
        program in ["ghostty", "kitty", "WezTerm"] -> "-f kitty"
        true -> "-f symbols --symbols block"
      end

    String.replace(@poster_preview, "CHAFA_OPTS", chafa_opts)
  end

  # Poster pane sizing: scales with the live terminal (measured per picker,
  # so resizing between menus just works), and below a minimum size posters
  # are skipped entirely — a pane that small is clutter, not art.
  @poster_min_cols 80
  @poster_min_rows 14

  # Live-resize floor, in PANE cells (fzf's <N(hidden) threshold compares
  # the preview pane's own width, NOT the terminal's — measured empirically;
  # a terminal-sized threshold here collapses the pane on normal displays).
  @poster_min_pane 35

  defp posters_fit? do
    {rows, cols} = tty_size()
    cols >= @poster_min_cols and rows >= @poster_min_rows
  end

  # Pane share per terminal-width tier; ASCII art gets more cells than
  # pixels because it needs them to stay readable.
  defp poster_tiers do
    if Config.posters() in ["ascii", "ascii-bg"], do: {50, 44, 38}, else: {42, 36, 30}
  end

  defp poster_width do
    {_rows, cols} = tty_size()
    {wide, mid, narrow} = poster_tiers()

    cond do
      cols >= 160 -> wide
      cols >= 120 -> mid
      true -> narrow
    end
  end

  # Live resize: Erlang spawns port children into their own session with no
  # controlling terminal, so fzf never receives SIGWINCH — it can't notice a
  # resize on its own (its `resize` event never fires under kino). The
  # escript, which does stay on the tty, polls the size instead and pushes a
  # recomputed layout + preview refresh into fzf over its --listen HTTP API.
  defp start_resize_watcher(port_file, api_key) do
    spawn(fn ->
      case await_fzf_port(port_file, 50) do
        nil -> :ok
        port -> watch_resize(port, api_key, tty_size())
      end
    end)
  end

  # fzf picks a random port (--listen 0) and tells us via the start bind.
  defp await_fzf_port(_file, 0), do: nil

  defp await_fzf_port(file, tries) do
    with {:ok, contents} <- File.read(file),
         {port, _} <- Integer.parse(String.trim(contents)) do
      port
    else
      _ ->
        Process.sleep(100)
        await_fzf_port(file, tries - 1)
    end
  end

  defp watch_resize(port, api_key, last_size) do
    Process.sleep(300)
    size = tty_size()
    if size != last_size, do: push_poster_layout(port, api_key)
    watch_resize(port, api_key, size)
  end

  # Two pushes: clear-screen makes fzf re-measure the terminal (it renders
  # at the stale size otherwise), then — once that redraw has landed — the
  # recomputed pane layout plus a preview re-render at the true new size.
  defp push_poster_layout(port, api_key) do
    post_fzf(port, api_key, "clear-screen")
    Process.sleep(150)

    post_fzf(
      port,
      api_key,
      "change-preview-window(right,#{poster_width()}%,border-left," <>
        "<#{@poster_min_pane}(hidden))+refresh-preview"
    )
  end

  defp post_fzf(port, api_key, command) do
    Req.post("http://127.0.0.1:#{port}",
      body: command,
      headers: [{"x-api-key", api_key}],
      retry: false,
      receive_timeout: 2_000
    )

    :ok
  rescue
    _ -> :ok
  end

  # Rows/columns of the terminal fzf will draw on. Must be asked in-process:
  # System.cmd children are spawned without a controlling terminal, so
  # `stty size </dev/tty` fails there even when kino itself is at one.
  defp tty_size do
    case {:io.rows(), :io.columns()} do
      {{:ok, rows}, {:ok, cols}} when rows > 0 and cols > 0 -> {rows, cols}
      _ -> {24, 80}
    end
  end

  defp pick_fzf(items, describe, header, preview, initial \\ nil) do
    # fzf positions are 1-based; pos(1) is where it starts anyway.
    pos = if initial && initial > 0, do: "+pos(#{initial + 1})", else: ""

    preview? =
      preview != nil and Config.posters() != "off" and
        System.find_executable("chafa") != nil and posters_fit?()
    if preview?, do: prune_posters()

    list =
      items
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {item, i} ->
        if preview?,
          do: "#{i}\t#{preview.(item) || "-"}\t#{describe.(item)}",
          else: "#{i}\t#{describe.(item)}"
      end)

    path = Path.join(System.tmp_dir!(), "kino-fzf-#{System.os_time(:millisecond)}")
    File.write!(path, list)
    port_file = path <> "-port"

    fzf =
      if preview? do
        # No --height: fullscreen on the alternate screen. An adaptive height
        # (~N%) would cap the window — and thus the poster, which keeps its
        # 2:3 aspect and is height-bound — at the list length.
        # The port file path is baked in literally: fzf runs binds in its own
        # $SHELL, where the outer sh's positional args don't exist.
        ~s(fzf --delimiter='\t' --with-nth=3.. --no-multi --reverse ) <>
          ~s(--header="$2" ) <>
          ~s[--preview-window='right,#{poster_width()}%,border-left,<#{@poster_min_pane}(hidden)' ] <>
          ~s[--listen 0 --bind 'start:execute-silent(echo "$FZF_PORT" > #{port_file})#{pos}' ] <>
          ~s(--preview '#{poster_preview_script()}' < "$1")
      else
        start_bind = if pos == "", do: "", else: ~s[--bind 'start:pos(#{initial + 1})' ]

        ~s(fzf --delimiter='\t' --with-nth=2.. --no-multi --reverse --height=~60% ) <>
          start_bind <> ~s(--header="$2" < "$1")
      end

    api_key = Base.encode16(:crypto.strong_rand_bytes(12))
    watcher = if preview?, do: start_resize_watcher(port_file, api_key)

    try do
      # fzf draws its UI on /dev/tty, reads the list from the redirected file,
      # and prints the chosen line on stdout — safe to run under System.cmd.
      case System.cmd("sh", ["-c", fzf, "sh", path, header],
             env: [{"FZF_API_KEY", api_key}]
           ) do
        {line, 0} ->
          {i, _} = line |> String.trim() |> Integer.parse()
          Enum.at(items, i)

        {_, _cancelled} ->
          nil
      end
    after
      if watcher, do: Process.exit(watcher, :kill)
      File.rm(path)
      File.rm(port_file)
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

    case Providers.resolve_magnet(magnet, opts) do
      {:ok, stream} -> IO.puts(Jason.encode!(stream))
      {:error, reason} -> die_resolve(reason)
    end
  end

  defp play(argv) do
    {target, opts} = magnet_args(argv, "play")

    url =
      case target do
        "magnet:" <> _ ->
          case Providers.resolve_magnet(target, opts) do
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

    unless Providers.any_configured?() do
      die("no debrid provider configured (RD_TOKEN or TORBOX_API_KEY) — run: kino setup")
    end

    case args do
      [target] -> {target, Keyword.take(opts, [:season, :episode])}
      _ -> die("#{cmd} needs exactly one magnet link (quote it!)")
    end
  end

  defp die_resolve({:not_cached, status, progress}) do
    die(%{error: "not cached on Real-Debrid", status: status, progress: progress})
  end

  defp die_resolve({:rd, 401, _}), do: die(rd_auth_error())
  defp die_resolve({:rd, 401}), do: die(rd_auth_error())

  defp die_resolve(reason), do: die("resolve failed: #{inspect(reason)}")

  # ── config ────────────────────────────────────────────────────────

  defp config do
    IO.puts(Jason.encode!(%{config_file: Config.path(), keys: Config.status()}))
  end

  # ── setup (interactive first-run wizard) ──────────────────────────

  defp setup do
    unless tty?(), do: die("setup is interactive — run it at a terminal")

    IO.puts(:stderr, IO.ANSI.format(["\n  🍿 ", :bright, "kino setup", :reset, " — two keys and you're watching\n"]))

    rd =
      prompt_key(
        "Real-Debrid API token",
        "https://real-debrid.com/apitoken",
        Application.get_env(:kino_app, :rd_token),
        &KinoTheatre.Doctor.check_rd/1
      )

    tmdb =
      prompt_key(
        "TMDB API key",
        "https://www.themoviedb.org/settings/api",
        Application.get_env(:kino_app, :tmdb_key),
        &KinoTheatre.Doctor.check_tmdb/1
      )

    torbox =
      prompt_optional_key(
        "TorBox API key (optional — second debrid provider)",
        "https://torbox.app/settings",
        Application.get_env(:kino_app, :torbox_api_key),
        &KinoTheatre.Doctor.check_torbox/1
      )

    keys = [{"RD_TOKEN", rd}, {"TMDB_API_KEY", tmdb}] ++ if(torbox, do: [{"TORBOX_API_KEY", torbox}], else: [])
    write_config_keys(keys)
    Config.load()

    IO.puts(:stderr, "")

    for {bin, why} <- [{"mpv", "required — plays the streams"}, {"fzf", "nicer pickers"}, {"chafa", "poster previews"}] do
      mark = if System.find_executable(bin), do: IO.ANSI.format([:green, "  ✓ "]), else: IO.ANSI.format([:red, "  ✗ "])
      IO.puts(:stderr, [mark, bin, IO.ANSI.format([:faint, " — #{why}", :reset])])
    end

    IO.puts(
      :stderr,
      "\n  saved to #{Config.path()}\n  optional extras (subtitles, Jackett, Jimaku) live in the same file.\n  all set — run: kino\n"
    )
  end

  # Ask for one key, validate it live against the real service, loop on
  # rejection. An existing key is shown masked (stars + its last characters)
  # with an explicit enter-to-keep, so a rerun never forces re-entry.
  defp prompt_key(name, url, existing, validate) do
    IO.puts(:stderr, IO.ANSI.format(["  ", :bright, name, :reset, :faint, "  #{url}", :reset]))

    if existing do
      IO.puts(
        :stderr,
        IO.ANSI.format([
          "  current: ",
          :yellow,
          mask(existing),
          :reset,
          :faint,
          "  — press enter to keep it, or paste a new key",
          :reset
        ])
      )
    end

    case IO.gets("  > ") do
      :eof ->
        die("setup cancelled")

      line ->
        case {String.trim(line), existing} do
          {"", nil} ->
            IO.puts(:stderr, IO.ANSI.format([:yellow, "  a key is required\n", :reset]))
            prompt_key(name, url, existing, validate)

          {"", key} ->
            IO.puts(:stderr, IO.ANSI.format([:faint, "  ✓ keeping #{mask(key)}\n", :reset]))
            key

          {key, _} ->
            IO.write(:stderr, "  checking… ")

            case validate.(key) do
              {:ok, detail} ->
                IO.puts(:stderr, IO.ANSI.format([:green, "✓ ", :reset, detail, "\n"]))
                key

              {:error, reason} ->
                IO.puts(:stderr, IO.ANSI.format([:red, "✗ #{reason}", :reset, " — try again\n"]))
                prompt_key(name, url, existing, validate)
            end
        end
    end
  end

  # Like prompt_key/4 but skippable: enter with nothing configured moves on
  # (returns nil), and a rejected key can still be skipped with enter.
  defp prompt_optional_key(name, url, existing, validate) do
    IO.puts(:stderr, IO.ANSI.format(["  ", :bright, name, :reset, :faint, "  #{url}", :reset]))

    if existing do
      IO.puts(
        :stderr,
        IO.ANSI.format([
          "  current: ",
          :yellow,
          mask(existing),
          :reset,
          :faint,
          "  — press enter to keep it, or paste a new key",
          :reset
        ])
      )
    else
      IO.puts(:stderr, IO.ANSI.format([:faint, "  press enter to skip", :reset]))
    end

    case IO.gets("  > ") do
      :eof ->
        existing

      line ->
        case {String.trim(line), existing} do
          {"", nil} ->
            IO.puts(:stderr, IO.ANSI.format([:faint, "  skipped\n", :reset]))
            nil

          {"", key} ->
            IO.puts(:stderr, IO.ANSI.format([:faint, "  ✓ keeping #{mask(key)}\n", :reset]))
            key

          {key, _} ->
            IO.write(:stderr, "  checking… ")

            case validate.(key) do
              {:ok, detail} ->
                IO.puts(:stderr, IO.ANSI.format([:green, "✓ ", :reset, detail, "\n"]))
                key

              {:error, reason} ->
                IO.puts(
                  :stderr,
                  IO.ANSI.format([:red, "✗ #{reason}", :reset, " — try again (enter skips)\n"])
                )

                prompt_optional_key(name, url, existing, validate)
            end
        end
    end
  end

  # Stars with the last few characters visible — enough to recognize which
  # key it is without exposing it.
  defp mask(key) when byte_size(key) > 8,
    do: String.duplicate("*", 12) <> binary_part(key, byte_size(key) - 4, 4)

  defp mask(_key), do: "************"

  # Update KEY=VALUE lines in the config file in place (comments and other
  # keys untouched); append keys that aren't there yet. Mode 600 — it holds
  # secrets.
  defp write_config_keys(pairs) do
    path = Config.path()
    File.mkdir_p!(Path.dirname(path))
    lines = case File.read(path) do
      {:ok, contents} -> String.split(contents, "\n")
      _ -> ["# kino config — created by kino setup"]
    end

    updated =
      Enum.reduce(pairs, lines, fn {key, value}, acc ->
        line = "#{key}=#{value}"

        if Enum.any?(acc, &String.starts_with?(String.trim_leading(&1), key <> "=")) do
          Enum.map(acc, fn l ->
            if String.starts_with?(String.trim_leading(l), key <> "="), do: line, else: l
          end)
        else
          acc ++ [line]
        end
      end)

    File.write!(path, Enum.join(updated, "\n"))
    File.chmod(path, 0o600)
  end

  # ── doctor (health checks) ────────────────────────────────────────

  defp doctor do
    IO.puts(:stderr, "\nkino doctor — checking everything kino depends on…\n")
    {results, healthy?} = KinoTheatre.Doctor.run()

    for section <- [:binaries, :services] do
      IO.puts(:stderr, IO.ANSI.format([:bright, "  #{section}", :reset]))

      for {^section, name, status, detail} <- results do
        {mark, color} =
          case status do
            :ok -> {"✓", :green}
            :skip -> {"–", :faint}
            :error -> {"✗", :red}
          end

        IO.puts(
          :stderr,
          IO.ANSI.format([
            color,
            "    #{mark} ",
            :reset,
            String.pad_trailing(name, 15),
            :faint,
            detail,
            :reset
          ])
        )
      end

      IO.puts(:stderr, "")
    end

    {rows, cols} = tty_size()

    IO.puts(
      :stderr,
      IO.ANSI.format([
        :bright,
        "  terminal",
        :reset,
        "\n    #{cols}×#{rows} · posters: #{Config.posters()} · skip: #{Config.skip()} · lang: #{Config.lang()}\n"
      ])
    )

    if healthy? do
      IO.puts(:stderr, IO.ANSI.format([:green, "  all good — happy watching\n", :reset]))
    else
      IO.puts(:stderr, IO.ANSI.format([:red, "  something's broken — fix the ✗ lines above\n", :reset]))
      System.halt(1)
    end
  end

  # ── update (self-replace the standalone binary) ───────────────────

  defp update do
    bin = System.get_env("__BURRITO_BIN_PATH")

    unless bin do
      die("self-update only works for the standalone binary — " <>
        "from a source checkout: git pull && mix escript.build")
    end

    current = Application.spec(:kino_app, :vsn) |> to_string()
    IO.puts(:stderr, "current: v#{current} — checking the latest release…")

    latest =
      KinoTheatre.UpdateCheck.fetch_latest() ||
        die("couldn't reach GitHub releases — try again later")

    if Version.compare(current, latest) != :lt do
      IO.puts(:stderr, "already up to date")
      IO.puts(Jason.encode!(%{updated: false, version: current}))
      System.halt(0)
    end

    asset =
      KinoTheatre.UpdateCheck.asset_name() ||
        die("no prebuilt binary for this platform — update from source")

    IO.puts(:stderr, "downloading v#{latest} (#{asset})…")

    body =
      case Req.get(KinoTheatre.UpdateCheck.download_url(asset),
             receive_timeout: 120_000,
             decode_body: false
           ) do
        {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) > 1_000_000 ->
          body

        {:ok, %{status: status}} ->
          die("download failed (HTTP #{status})")

        {:error, reason} ->
          die("download failed: #{inspect(reason)}")
      end

    # Stage next to the target, then rename — atomic on the same filesystem,
    # so a failed download can never leave a half-written kino behind.
    staged = bin <> ".new"

    with :ok <- File.write(staged, body),
         :ok <- File.chmod(staged, 0o755),
         :ok <- File.rename(staged, bin) do
      IO.puts(:stderr, "✔ updated v#{current} → v#{latest} (#{bin})")
      IO.puts(Jason.encode!(%{updated: true, from: current, to: latest}))
    else
      {:error, reason} ->
        File.rm(staged)
        die("couldn't replace #{bin} (#{inspect(reason)}) — is that location writable?")
    end
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
      kino                   open the interactive menu (Continue / Featured / Search)
      kino watch "<title>"   [--auto] [--binge] [--raw] [--backend apibay|nyaa|anime] [--limit N]
      kino download "<title>" same flow as watch, but saves the file (KINO_DOWNLOAD_DIR)
      kino featured          browse what's trending on TMDB and pick something
      kino resume            instantly resume the last thing you watched
      kino continue          pick from your watch history
      kino search "<query>"  [--backend apibay|nyaa|anime] [--limit N] [--json|--pretty]
      kino resolve <magnet>  [--season N] [--episode N]
      kino play <magnet|url> [--season N] [--episode N]
      kino setup             interactive first-run wizard: keys in, validated live
      kino doctor            check binaries, keys, and every service kino talks to
      kino config
      kino update            self-update the standalone binary to the latest release

    watch is interactive: pick the title (TMDB), for shows the season and
    episode, then a source — it resolves on your debrid account and plays
    in mpv. --raw skips TMDB and searches torrents by text directly.
    search prints a readable list at a terminal and JSON when piped.
    Config: #{Config.path()}
    """)

    System.halt(exit_code)
  end
end
