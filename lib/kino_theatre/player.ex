defmodule KinoTheatre.Player do
  @moduledoc """
  Launches an external desktop player for a stream URL.

  Only works when the Phoenix server runs on the same machine as the browser
  (the localhost use case this app is built for). GUI apps are opened with
  macOS `open -a`; mpv (a CLI binary) is launched detached so it keeps running
  without blocking the caller. In every case the URL is passed as a separate
  argument, never interpolated into a shell command.
  """

  # Friendly name -> macOS application bundle, for `open -a`.
  @gui %{vlc: "VLC", iina: "IINA"}

  @doc "Open `url` in the given player (`:vlc`, `:iina`, or `:mpv`)."
  def open(:mpv, url) when is_binary(url) do
    case System.find_executable("mpv") do
      nil ->
        {:error, "mpv is not installed or not on the server's PATH"}

      bin ->
        # `&` backgrounds mpv inside sh so this returns immediately; the URL is
        # positional ($1), so it is not parsed by the shell.
        System.cmd("sh", ["-c", ~s("#{bin}" "$1" >/dev/null 2>&1 &), "sh", url])
        :ok
    end
  end

  def open(app, url) when is_map_key(@gui, app) and is_binary(url) do
    case System.cmd("open", ["-a", @gui[app], url], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, _code} -> {:error, message(@gui[app], out)}
    end
  end

  @doc """
  Hand a magnet link to the OS default handler (the user's torrent client) —
  a way to download DMCA'd/uncached torrents directly via P2P, bypassing RD.
  """
  def open_magnet("magnet:" <> _ = magnet) do
    case System.cmd("open", [magnet], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, _code} -> {:error, message("torrent client", out)}
    end
  end

  defp message(app, out) do
    case String.trim(out) do
      "" -> "#{app} could not be opened — is it installed?"
      other -> other
    end
  end
end
