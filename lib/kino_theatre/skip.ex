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
  local opts = { windows = "", mode = "ask" }
  options.read_options(opts, "kino-skip")

  local windows = {}
  for s, e in string.gmatch(opts.windows, "([%d%.]+)%-([%d%.]+)") do
    windows[#windows + 1] = { s = tonumber(s), e = tonumber(e), done = false }
  end

  local skip_titles = {
    "^op%f[%A]", "opening", "^intro%f[%A]", "^recap", "^avant",
    "^ed%f[%A]", "ending", "credits", "^preview", "^next episode"
  }
  local skipped_chapters = {}
  local overlay = mp.create_osd_overlay("ass-events")
  local active = nil

  local function show_prompt(what)
    local label = what:gsub("[{}\\\\]", "")
    overlay.data = "{\\\\an9\\\\fs30\\\\bord2\\\\shad1\\\\b1}  ⏭  Skip " ..
      label .. " — hold TAB  "
    overlay:update()
    msg.info("offering skip: " .. what)
  end

  local function hide_prompt()
    overlay.data = ""
    overlay:update()
  end

  local function mark_done(zone)
    if zone.window then zone.window.done = true end
    if zone.chidx then skipped_chapters[zone.chidx] = true end
  end

  local function do_skip(zone)
    mark_done(zone)
    mp.commandv("seek", zone.target, "absolute+exact")
    mp.osd_message("kino: skipped " .. zone.what, 2)
    msg.info("skipped " .. zone.what)
  end

  local function window_zone(t)
    for i, w in ipairs(windows) do
      if not w.done and t >= w.s and t < w.e - 1 then
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
    return { target = nxt.time, what = ch.title, key = "c" .. idx, chidx = idx }
  end

  mp.observe_property("time-pos", "number", function(_, t)
    if not t then return end
    local zone = window_zone(t) or chapter_zone()

    if not zone then
      if active then active = nil hide_prompt() end
      return
    end

    if opts.mode == "auto" then
      do_skip(zone)
      return
    end

    if not active or active.key ~= zone.key then
      active = zone
      show_prompt(zone.what)
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

  defp windows(%{anime: true, episode: ep} = ctx) when is_integer(ep) do
    title = ctx[:search_title] || ctx[:title]
    cached(title, ep, fn -> fetch_windows(title, ep) end)
  end

  defp windows(_ctx), do: ""

  defp fetch_windows(title, ep) do
    with {:ok, [anime | _]} <- Kitsu.search(title),
         {:ok, mal} <- Kitsu.mal_id(anime.id),
         {:ok, results} <- aniskip(mal, ep) do
      Enum.map_join(results, ";", fn %{"interval" => %{"startTime" => s, "endTime" => e}} ->
        "#{s}-#{e}"
      end)
    else
      _ -> ""
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

  # Windows cache — an empty result is cached too (negative cache), so shows
  # AniSkip doesn't know never cost repeat lookups.
  defp cached(title, ep, fetch) do
    dir = Path.join(System.tmp_dir!(), "kino-skip")
    File.mkdir_p!(dir)
    key = :erlang.md5("#{title}-#{ep}") |> Base.encode16(case: :lower) |> binary_part(0, 16)
    path = Path.join(dir, key)
    fresh_after = System.os_time(:second) - @cache_max_age_s

    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} when mtime > fresh_after ->
        File.read!(path)

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
