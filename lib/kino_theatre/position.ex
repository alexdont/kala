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

  -- Track memory: whenever the user switches subtitle or audio track, save
  -- "sid aid" plus the media filename (ids are only meaningful for the same
  -- file — kino checks the filename before restoring). Saves are gated on
  -- file-loaded so teardown/no-track states can't clobber a real choice.
  local ready = false
  mp.register_event("file-loaded", function() ready = true end)
  mp.register_event("end-file", function() ready = false end)

  local function save_tracks()
    if opts.tracks == "" or not ready then return end
    local sid = mp.get_property("sid") or "no"
    local aid = mp.get_property("aid") or "no"
    local fname = mp.get_property("filename") or ""
    local f = io.open(opts.tracks, "w")
    if f then
      f:write(sid .. " " .. aid .. "\\n" .. fname)
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

  -- Periodic saves never decide "finished": for live-ish streams (HLS
  -- transcode) duration tracks the position, so percent-based rules
  -- misfire. Only a real end-of-file clears the position.
  local function save()
    local pos = mp.get_property_number("time-pos")
    if not pos then return end
    if pos < 30 then pos = 0 end
    write(math.floor(pos))
  end

  mp.add_periodic_timer(5, save)
  mp.register_event("shutdown", save)
  -- "done" doubles as the watched marker (kino's Up Next / ✓ in pickers);
  -- it parses as no-resume, so a rewatch starts from the beginning.
  mp.register_event("end-file", function(e)
    if e and e.reason == "eof" then
      if opts.file == "" then return end
      local f = io.open(opts.file, "w")
      if f then f:write("done") f:close() end
    end
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
        tracks = tracks_file(key)

        # -append: a plain --script-opts= would replace the whole list and
        # wipe other scripts' opts (e.g. the skip windows).
        args =
          [
            "--script=#{script_path()}",
            "--script-opts-append=kino-file=#{file}",
            "--script-opts-append=kino-tracks=#{tracks}"
          ] ++ track_args(tracks, filename)

        case read(file) do
          nil -> {args, nil}
          secs -> {args ++ ["--start=#{secs}"], format(secs)}
        end
    end
  rescue
    _ -> {[], nil}
  end

  # Restore "--sid=N --aid=N" only when the remembered tracks belong to this
  # exact file — ids mean nothing on a different release. "no" (subtitles
  # deliberately off) restores too.
  defp track_args(tracks_path, filename) do
    with true <- is_binary(filename),
         {:ok, contents} <- File.read(tracks_path),
         [ids, stored_name] <- String.split(contents, "\n", parts: 2),
         true <- String.trim(stored_name) == filename,
         [sid, aid] <- String.split(String.trim(ids), " ", parts: 2) do
      ["--sid=#{sid}", "--aid=#{aid}"]
    else
      _ -> []
    end
  end

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
