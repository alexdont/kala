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
  -- kino position tracker: persists time-pos so playback survives crashes.
  -- Written by kino on every launch; do not edit.
  local options = require "mp.options"
  local opts = { file = "" }
  options.read_options(opts, "kino")

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
  mp.register_event("end-file", function(e)
    if e and e.reason == "eof" then write(0) end
  end)
  """

  @doc """
  mpv arguments for position tracking + resume, as `{args, resume_at}`
  where `resume_at` is a human-readable time when resuming, else nil.
  Best-effort: any failure returns `{[], nil}` — never breaks playback.
  """
  def mpv_args(ctx) do
    case key(ctx) do
      nil ->
        {[], nil}

      key ->
        file = position_file(key)
        args = ["--script=#{script_path()}", "--script-opts=kino-file=#{file}"]

        case read(file) do
          nil -> {args, nil}
          secs -> {args ++ ["--start=#{secs}"], format(secs)}
        end
    end
  rescue
    _ -> {[], nil}
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
