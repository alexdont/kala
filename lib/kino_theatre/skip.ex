defmodule KinoTheatre.Skip do
  @moduledoc """
  Intro/credits skipping with a Netflix-style on-screen prompt.

  Detection is two-layered, through one injected mpv Lua script:

    1. AniSkip windows (anime) — community-submitted OP/ED timestamps by
       MyAnimeList id + episode, resolved via the Kitsu mapping we already
       use. Fetched async alongside subtitles; cached 30 days.
    2. Chapter names — releases authored with "Opening"/"Intro"/"Recap"/
       "Credits"/… chapters (only chapters ≤ 4 minutes, so a mislabeled
       real chapter never gets eaten).

  What happens on detection is the KINO_SKIP mode:

    * "ask" (default) — a "⏭ Skip — TAB" button appears on the video while
      the intro plays; Tab jumps past it, ignoring it watches it. Openings
      are part of the show — skipping is the user's call.
    * "auto" — jump immediately, with a brief OSD note.
    * "off" — no script at all.

  Outside a detected intro, Tab is a +85s seek — the universal "no data,
  just jump the intro" key. No fingerprint detection on purpose: it needs
  several episodes' audio downloaded and analyzed before playback, which
  fights kino's instant-start, low-resource design.
  """

  alias KinoTheatre.{Config, Kitsu}

  @script """
  -- kino skip: intro/credits skipping (AniSkip windows + named chapters).
  -- mode=ask shows a Skip button and waits for TAB; mode=auto jumps.
  -- Written by kino on every launch; do not edit.
  local options = require "mp.options"
  local msg = require "mp.msg"
  local opts = { windows = "", mode = "ask", stinger = "" }
  options.read_options(opts, "kino-skip")

  -- "start-end@episodelength;…" — the submitted episode length rides along
  -- so mismatched cuts can be rejected at runtime (@0 / missing = unknown).
  local windows = {}
  for s, e, len in string.gmatch(opts.windows, "([%d%.]+)%-([%d%.]+)@?([%d%.]*)") do
    windows[#windows + 1] =
      { s = tonumber(s), e = tonumber(e), len = tonumber(len) or 0, done = false }
  end

  -- AniSkip timestamps only make sense for the cut they were submitted
  -- against: if this file's duration is >15s off the submitted episode
  -- length, the window would point at the wrong seconds — drop it.
  local function usable(w)
    if w.len == 0 then return true end
    -- duration unknown for the first moments — hold off rather than offer
    -- a window that may belong to a different cut.
    local dur = mp.get_property_number("duration")
    if not dur then return false end
    if math.abs(dur - w.len) > 15 then
      if not w.warned then
        w.warned = true
        msg.info(string.format(
          "dropping window %.0f-%.0f: episode length mismatch (file %.0fs, submitted %.0fs)",
          w.s, w.e, dur, w.len))
      end
      return false
    end
    return true
  end

  local skip_titles = {
    "^op%f[%A]", "opening", "^intro%f[%A]", "^recap", "^avant",
    "^ed%f[%A]", "ending", "credits", "^preview", "^next episode"
  }
  local skipped_chapters = {}
  local overlay = mp.create_osd_overlay("ass-events")
  local active = nil

  local function show_prompt(what, credits)
    local label = what:gsub("[{}\\\\]", "")
    local warn = ""
    if credits and opts.stinger ~= "" then
      warn = "  ⚠ post-credit scene!"
    end
    overlay.data = "{\\\\an9\\\\fs30\\\\bord2\\\\shad1\\\\b1}  ⏭  Skip " ..
      label .. " — hold TAB" .. warn .. "  "
    overlay:update()
    msg.info("offering skip: " .. what .. warn)
  end

  local function hide_prompt()
    overlay.data = ""
    overlay:update()
  end

  local function mark_done(zone)
    if zone.window then zone.window.done = true end
    if zone.chidx then skipped_chapters[zone.chidx] = true end
  end

  -- Marking "done" is auto-mode only: it stops the auto-skip from looping
  -- when the user rewinds to deliberately watch an opening. In ask mode
  -- nothing is marked — the offer simply reappears whenever the playhead
  -- is inside a window, so it works again after a skip, a rewind, a replay.
  local function do_skip(zone)
    mp.commandv("seek", zone.target, "absolute+exact")
    mp.osd_message("kino: skipped " .. zone.what, 2)
    msg.info("skipped " .. zone.what)
  end

  local function window_zone(t)
    for i, w in ipairs(windows) do
      if usable(w) and not w.done and t >= w.s and t < w.e - 1 then
        return { target = w.e, what = "opening/ending", key = "w" .. i, window = w }
      end
    end
    return nil
  end

  local function chapter_zone()
    local idx = mp.get_property_number("chapter")
    if idx == nil or idx < 0 or skipped_chapters[idx] then return nil end
    local chapters = mp.get_property_native("chapter-list") or {}
    local ch = chapters[idx + 1]
    local nxt = chapters[idx + 2]
    if not ch or not ch.title or ch.title == "" or not nxt then return nil end
    local title = string.lower(ch.title)
    local hit = false
    for _, p in ipairs(skip_titles) do
      if string.find(title, p) then hit = true break end
    end
    if not hit then return nil end
    local dur = nxt.time - ch.time
    if dur <= 0 or dur > 240 then return nil end
    local credits = title:find("credit") ~= nil or title:find("ending") ~= nil
    return { target = nxt.time, what = ch.title, key = "c" .. idx, chidx = idx,
             credits = credits }
  end

  -- Stinger reminder: as the runtime approaches the end, warn once that
  -- there's a scene worth staying for (movies only; kino sets the opt from
  -- TMDB's duringcreditsstinger/aftercreditsstinger keywords).
  local stinger_warned = false
  local function stinger_reminder(t)
    if opts.stinger == "" or stinger_warned then return end
    local dur = mp.get_property_number("duration")
    if dur and dur > 600 and t > dur - 150 then
      stinger_warned = true
      mp.osd_message("kino: this movie has a post-credit scene — don't quit early", 6)
      msg.info("stinger reminder shown (" .. opts.stinger .. ")")
    end
  end

  mp.observe_property("time-pos", "number", function(_, t)
    if not t then return end
    stinger_reminder(t)
    local zone = window_zone(t) or chapter_zone()

    if not zone then
      if active then active = nil hide_prompt() end
      return
    end

    if opts.mode == "auto" then
      mark_done(zone)
      do_skip(zone)
      return
    end

    if not active or active.key ~= zone.key then
      active = zone
      show_prompt(zone.what, zone.credits)
    end
  end)

  -- Hold TAB ~0.6s to skip — a stray tap does nothing (an accidental +85s
  -- jump is annoying to undo). Releasing early cancels.
  local hold_timer = nil

  local function fire()
    hold_timer = nil
    if active then
      do_skip(active)
      active = nil
      hide_prompt()
    else
      mp.commandv("seek", 85, "relative")
      mp.osd_message("kino: +85s", 1)
      msg.info("blind +85s")
    end
  end

  mp.add_key_binding("TAB", "kino-skip", function(e)
    if e.event == "down" and not hold_timer then
      hold_timer = mp.add_timeout(0.6, fire)
      mp.osd_message("keep holding to skip…", 0.6)
    elseif e.event == "up" and hold_timer then
      hold_timer:kill()
      hold_timer = nil
      mp.osd_message("", 0)
    end
  end, { complex = true })
  """

  @cache_max_age_s 30 * 24 * 3600

  @doc "mpv `--script` + mode arguments (instant, no network). [] when disabled."
  def script_args do
    case Config.skip() do
      "off" ->
        []

      mode ->
        ["--script=#{script_path()}", "--script-opts-append=kino-skip-mode=#{mode}"]
    end
  rescue
    _ -> []
  end

  @doc """
  AniSkip OP/ED windows for an anime episode as a `--script-opts-append`
  argument. Networked (Kitsu → MAL id → AniSkip) — call it from the async
  pre-launch task, not the launch path. Best-effort: [] on any failure.
  """
  def window_args(ctx) do
    with true <- Config.skip() != "off",
         spec when spec != "" <- windows(ctx) do
      ["--script-opts-append=kino-skip-windows=#{spec}"]
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc """
  Post-credit stinger handling for movies: prints a terminal alert and, when
  the skip script runs, passes the flags so the credits-skip button warns
  and an end-of-runtime OSD reminder fires. Networked (one TMDB call) —
  call from the async pre-launch task. [] for TV / no stingers / failure.
  """
  def stinger_args(ctx) do
    case stinger_parts(ctx) do
      [] ->
        []

      parts ->
        IO.puts(:stderr, "🎬 stinger alert: #{stinger_label(parts)} — don't skip the credits!")

        if Config.skip() == "off",
          do: [],
          else: ["--script-opts-append=kino-skip-stinger=#{Enum.join(parts, ",")}"]
    end
  end

  @doc """
  Which stingers a movie has: [] | ["during"] | ["after"] | ["during","after"].
  Disk-cached, so the pre-launch task warms it and the Now Playing screen
  reads it instantly.
  """
  def stinger_parts(%{type: "movie", tmdb_id: id}) when not is_nil(id) do
    spec =
      cached("stinger-#{id}", fn ->
        case KinoTheatre.Tmdb.stingers(id) do
          {false, false} ->
            ""

          {during, after_credits} ->
            [{during, "during"}, {after_credits, "after"}]
            |> Enum.filter(&elem(&1, 0))
            |> Enum.map_join(",", &elem(&1, 1))
        end
      end)

    if spec == "", do: [], else: String.split(spec, ",")
  rescue
    _ -> []
  end

  def stinger_parts(_ctx), do: []

  @doc "\"during-credits and after-credits scenes\" — human label for stinger parts."
  def stinger_label(parts) do
    label =
      Enum.map_join(parts, " and ", fn
        "during" -> "during-credits"
        "after" -> "after-credits"
      end)

    "#{label} #{if length(parts) > 1, do: "scenes", else: "scene"}"
  end

  defp windows(%{anime: true, episode: ep} = ctx) when is_integer(ep) do
    title = ctx[:search_title] || ctx[:title]
    cached("#{title}-#{ep}", fn -> fetch_windows(title, ep) end)
  end

  defp windows(_ctx), do: ""

  defp fetch_windows(title, ep) do
    with mal when mal != nil <- mal_id_for(title),
         {:ok, results} <- aniskip(mal, ep) do
      Enum.map_join(results, ";", fn %{"interval" => %{"startTime" => s, "endTime" => e}} = r ->
        "#{s}-#{e}@#{r["episodeLength"] || 0}"
      end)
    else
      _ -> ""
    end
  end

  # Kitsu's MAL mappings are often missing for new seasonal shows (that's
  # how "Marriage Toxin" slipped through) — fall back to AniList, whose
  # search returns the MAL id directly.
  defp mal_id_for(title) do
    with {:ok, [anime | _]} <- Kitsu.search(title),
         {:ok, mal} <- Kitsu.mal_id(anime.id) do
      mal
    else
      _ -> anilist_mal_id(title)
    end
  end

  defp anilist_mal_id(title) do
    case Req.post("https://graphql.anilist.co",
           json: %{
             query: "query($s:String){Media(search:$s,type:ANIME){idMal}}",
             variables: %{s: title}
           },
           retry: false,
           receive_timeout: 8_000
         ) do
      {:ok, %{status: 200, body: %{"data" => %{"Media" => %{"idMal" => mal}}}}} -> mal
      _ -> nil
    end
  end

  defp aniskip(mal, ep) do
    case Req.get("https://api.aniskip.com/v2/skip-times/#{mal}/#{ep}",
           params: [{"types[]", "op"}, {"types[]", "ed"}, {"episodeLength", 0}],
           retry: false,
           receive_timeout: 8_000
         ) do
      {:ok, %{status: 200, body: %{"found" => true, "results" => results}}} -> {:ok, results}
      _ -> {:error, :no_skip_times}
    end
  end

  # Windows cache. Found timestamps keep for 30 days; an empty result only
  # for a day — the community submits timestamps while a season airs, so
  # "no data" is often just "no data yet".
  @empty_cache_max_age_s 24 * 3600

  defp cached(cache_key, fetch) do
    dir = Path.join(System.tmp_dir!(), "kino-skip")
    File.mkdir_p!(dir)
    key = :erlang.md5(cache_key) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    path = Path.join(dir, key)

    with {:ok, %{mtime: mtime}} <- File.stat(path, time: :posix),
         {:ok, spec} <- File.read(path),
         ttl = if(spec == "", do: @empty_cache_max_age_s, else: @cache_max_age_s),
         true <- mtime > System.os_time(:second) - ttl do
      spec
    else
      _ ->
        spec = fetch.()
        File.write(path, spec)
        spec
    end
  end

  # Rewritten on every launch so it always matches this app version.
  defp script_path do
    dir = Application.get_env(:kino_app, :data_dir) || Path.join(System.user_home!(), ".kino")
    File.mkdir_p!(dir)
    path = Path.join(dir, "skip.lua")
    File.write!(path, @script)
    path
  end
end
