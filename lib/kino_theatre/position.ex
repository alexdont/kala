defmodule KinoTheatre.Position do
  @moduledoc """
  Exact playback-position memory, crash-safe.

  A tiny Lua script (mpv has a built-in Lua engine — no dependencies) writes
  the current second to a file every 5 seconds while mpv plays, so the
  position survives player crashes and power loss. The file is keyed by
  title + episode — NOT by stream URL — so switching to a different source
  of the same episode resumes from the same spot.

  Positions under 30s aren't kept (no point), and finishing a title (>95%)
  clears it so a rewatch starts from the beginning.
  """

  @min_resume 30

  @script """
  -- kino position tracker: persists time-pos so playback survives crashes,
  -- and remembers the selected subtitle/audio tracks per source.
  -- Written by kino on every launch; do not edit.
  local options = require "mp.options"
  local opts = { file = "", tracks = "" }
  options.read_options(opts, "kino")

  -- Per-series track memory: when the user switches audio/subtitle track,
  -- remember the LANGUAGE (not the track id — ids differ between releases,
  -- languages carry across every episode/season). Saved as "ALANG SLANG"
  -- (slang "off" = subtitles disabled). kino applies it to the whole series
  -- via --alang/--slang, overriding the global default just for this show.
  -- A 2s settle window after load ignores mpv's own initial auto-selection
  -- so only a real manual change is recorded.
  local ready = false
  local settled = false

  mp.register_event("file-loaded", function()
    ready = true
    settled = false
    mp.add_timeout(2, function() settled = true end)
  end)
  mp.register_event("end-file", function() ready = false end)

  local function save_tracks()
    if opts.tracks == "" or not ready or not settled then return end
    local alang = mp.get_property("current-tracks/audio/lang")
    local slang = mp.get_property("current-tracks/sub/lang")
    -- No selected sub track = subtitles off (the user disabled them).
    if slang == nil then slang = "off" end
    -- Untagged audio has no language to remember — skip rather than store junk.
    if alang == nil or alang == "" then return end
    local f = io.open(opts.tracks, "w")
    if f then
      f:write(alang .. " " .. slang)
      f:close()
    end
  end

  mp.observe_property("sid", "native", save_tracks)
  mp.observe_property("aid", "native", save_tracks)

  local function write(n)
    if opts.file == "" then return end
    local f = io.open(opts.file, "w")
    if f then
      f:write(string.format("%d", n))
      f:close()
    end
  end

  -- "done" is the watched marker (Up Next / grayed ✓ in pickers); it parses
  -- as no-resume, so a rewatch starts over. An episode counts as watched at
  -- 90% — you stop before the credits/ED. Guard against live-ish streams
  -- (HLS transcode) where duration just tracks position and 90% is always
  -- true: only trust the percentage once we've actually seen the playhead
  -- in the first half (real duration), which never happens when dur≈pos.
  local saw_early = false

  local function mark_done()
    if opts.file == "" then return end
    local f = io.open(opts.file, "w")
    if f then f:write("done") f:close() end
  end

  local function save()
    local pos = mp.get_property_number("time-pos")
    if not pos then return end
    local dur = mp.get_property_number("duration")

    if dur and dur > 0 and pos < dur * 0.5 then saw_early = true end

    if saw_early and dur and dur > 0 and pos >= dur * 0.85 then
      mark_done()
      return
    end

    if pos < 30 then pos = 0 end
    write(math.floor(pos))
  end

  mp.add_periodic_timer(5, save)
  mp.register_event("shutdown", save)
  mp.register_event("end-file", function(e)
    if e and e.reason == "eof" then mark_done() end
  end)
  """

  @doc """
  mpv arguments for position tracking + resume, as `{args, resume_at}`
  where `resume_at` is a human-readable time when resuming, else nil.
  Best-effort: any failure returns `{[], nil}` — never breaks playback.
  """
  def mpv_args(ctx, filename \\ nil) do
    case key(ctx) do
      nil ->
        {[], nil}

      key ->
        file = position_file(key)
        # Track memory is per-SERIES (not per-episode/file): a language
        # choice on one episode applies to every episode and season.
        tracks = tracks_file(series_key(ctx))

        # -append: a plain --script-opts= would replace the whole list and
        # wipe other scripts' opts (e.g. the skip windows).
        args =
          [
            "--script=#{script_path()}",
            "--script-opts-append=kino-file=#{file}",
            "--script-opts-append=kino-tracks=#{tracks}"
          ] ++ track_args(tracks)

        case read(file) do
          nil -> {args, nil}
          secs -> {args ++ ["--start=#{secs}"], format(secs)}
        end
    end
  rescue
    _ -> {[], nil}
  end

  # Apply the series' remembered languages as --alang/--slang, overriding the
  # global default just for this show. Stored as "ALANG SLANG" (slang "off" =
  # subtitles disabled). Languages carry across releases; track ids don't.
  defp track_args(tracks_path) do
    with {:ok, contents} <- File.read(tracks_path),
         [alang, slang] <- contents |> String.trim() |> String.split(" ", parts: 2) do
      audio = if alang in ["", "no", "off"], do: [], else: ["--aid=auto", "--alang=#{KinoTheatre.Player.lang_codes(alang)}"]

      subs =
        case slang do
          s when s in ["off", "no", ""] -> ["--sid=no"]
          s -> ["--sid=auto", "--slang=#{KinoTheatre.Player.lang_codes(s)}", "--sub-auto=fuzzy"]
        end

      audio ++ subs
    else
      _ -> []
    end
  end

  # Series-level key for track memory: type + tmdb id, no season/episode.
  defp series_key(%{type: type, tmdb_id: id}) when type in ["movie", "tv"] and not is_nil(id),
    do: "#{type}-#{id}"

  defp series_key(_), do: "unknown"

  defp tracks_file(key) do
    dir = Path.join(data_dir(), "tracks")
    File.mkdir_p!(dir)
    Path.join(dir, key)
  end

  @doc "True when this title/episode was watched to the end (mpv hit eof)."
  def finished?(ctx) do
    with key when is_binary(key) <- key(ctx),
         {:ok, body} <- File.read(position_file(key)) do
      String.trim(body) == "done"
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  True when this episode counts as watched: marked "done", OR — when the
  episode runtime (seconds) is known — the saved position is past 85% of it.
  The runtime check retroactively catches episodes watched before the 85%
  marker existed (their position is a plain number, not "done").
  """
  def watched?(ctx, runtime_s \\ nil) do
    finished?(ctx) or
      (is_number(runtime_s) and runtime_s > 0 and
         case saved_seconds(ctx) do
           n when is_integer(n) -> n >= runtime_s * 0.85
           _ -> false
         end)
  rescue
    _ -> false
  end

  @doc "Manually mark an episode watched (write \"done\") or unwatched (clear it)."
  def set_watched(ctx, true) do
    with key when is_binary(key) <- key(ctx), do: File.write(position_file(key), "done")
    :ok
  rescue
    _ -> :ok
  end

  def set_watched(ctx, false) do
    with key when is_binary(key) <- key(ctx), do: File.rm(position_file(key))
    :ok
  rescue
    _ -> :ok
  end

  defp saved_seconds(ctx) do
    with key when is_binary(key) <- key(ctx),
         {:ok, body} <- File.read(position_file(key)),
         {n, _} <- Integer.parse(String.trim(body)) do
      n
    else
      _ -> nil
    end
  end

  @doc """
  When the position file was last written (posix seconds), or nil. The Lua
  tracker saves every 5s while mpv runs — a stale mtime means mpv is gone.
  """
  def last_saved_at(ctx) do
    with key when is_binary(key) <- key(ctx),
         {:ok, %{mtime: mtime}} <- File.stat(position_file(key), time: :posix) do
      mtime
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc "Human-readable stored position for a play context, or nil."
  def resume_at(ctx) do
    with key when is_binary(key) <- key(ctx),
         secs when is_integer(secs) <- read(position_file(key)) do
      format(secs)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp key(%{type: type, tmdb_id: id} = ctx) when type in ["movie", "tv"] and not is_nil(id) do
    base = "#{type}-#{id}"

    cond do
      ctx[:season] && ctx[:episode] -> "#{base}-s#{ctx[:season]}e#{ctx[:episode]}"
      ctx[:episode] -> "#{base}-e#{ctx[:episode]}"
      true -> base
    end
  end

  defp key(_ctx), do: nil

  defp read(file) do
    with {:ok, body} <- File.read(file),
         {secs, _} when secs >= @min_resume <- Integer.parse(String.trim(body)) do
      secs
    else
      _ -> nil
    end
  end

  defp format(secs) do
    h = div(secs, 3600)
    m = div(rem(secs, 3600), 60)
    s = rem(secs, 60)

    if h > 0,
      do: "#{h}:#{pad(m)}:#{pad(s)}",
      else: "#{m}:#{pad(s)}"
  end

  defp pad(n), do: String.pad_leading("#{n}", 2, "0")

  # Rewritten on every launch so it always matches this app version.
  defp script_path do
    File.mkdir_p!(data_dir())
    path = Path.join(data_dir(), "position.lua")
    File.write!(path, @script)
    path
  end

  defp position_file(key) do
    dir = Path.join(data_dir(), "positions")
    File.mkdir_p!(dir)
    Path.join(dir, key)
  end

  defp data_dir do
    Application.get_env(:kino_app, :data_dir) || Path.join(System.user_home!(), ".kino")
  end
end
