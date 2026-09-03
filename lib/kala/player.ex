defmodule Kala.Player do
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

  # Low-RAM defaults, per the project goal (~200 MB while watching):
  # mpv's stock demuxer cache is 150+50 MiB and balloons on high-bitrate
  # remuxes; ~100 MiB of buffer is plenty over a debrid HTTPS stream.
  # Decoder threads default to the core count and each adds frame buffers.
  # hwdec=auto-safe offloads decode to the GPU when safely available.
  # Users override or extend via KALA_MPV_ARGS (later args win in mpv).
  @mpv_defaults [
    "--demuxer-max-bytes=64MiB",
    "--demuxer-max-back-bytes=32MiB",
    "--vd-lavc-threads=4",
    "--hwdec=auto-safe"
  ]

  @doc """
  Open `url` in the given player (`:vlc`, `:iina`, or `:mpv`). For mpv,
  `extra_args` are passed before the URL (e.g. `--sub-file=<path>`).
  """
  def open(player, url, extra_args \\ [])

  def open(:mpv, url, extra_args) when is_binary(url) and is_list(extra_args) do
    case System.find_executable("mpv") do
      nil ->
        {:error, "mpv is not installed or not on the server's PATH"}

      bin ->
        user_args =
          case Application.get_env(:kala_app, :mpv_args) do
            args when is_binary(args) -> String.split(args, ~r/\s+/, trim: true)
            _ -> []
          end

        # `&` backgrounds mpv inside sh so this returns immediately; every
        # argument is positional ("$@"), so nothing is parsed by the shell.
        System.cmd(
          "sh",
          ["-c", ~s("$@" >/dev/null 2>&1 &), "sh", bin] ++
            @mpv_defaults ++ lang_args() ++ user_args ++ extra_args ++ [url]
        )

        :ok
    end
  end

  # Auto-select the preferred audio + subtitle track inside a release so the
  # user doesn't have to switch manually. mpv picks the first track whose
  # language tag matches; multiple codes cover the tagging variants (ISO
  # 639-1 "ru", 639-2 "rus", and common English aliases). An explicit
  # --aid/--sid from track memory (extra_args) still overrides these, since
  # a specific id beats a language preference in mpv.
  @lang_aliases %{
    "ru" => "ru,rus,russian",
    "en" => "en,eng,english",
    "ja" => "ja,jpn,jp,japanese",
    "es" => "es,spa,spanish,esp",
    "fr" => "fr,fre,fra,french",
    "de" => "de,ger,deu,german",
    "it" => "it,ita,italian",
    "pt" => "pt,por,portuguese",
    "uk" => "uk,ukr,ukrainian",
    "zh" => "zh,chi,zho,chinese",
    "ko" => "ko,kor,korean",
    "hi" => "hi,hin,hindi"
  }

  defp lang_args do
    audio =
      case Kala.Config.lang() do
        l when is_binary(l) and l != "" -> ["--alang=#{aliases(l)}"]
        _ -> []
      end

    subs =
      case Kala.Config.subs_lang() do
        l when is_binary(l) and l != "" -> ["--slang=#{aliases(l)}", "--sub-auto=fuzzy"]
        _ -> []
      end

    audio ++ subs
  end

  @doc "Comma-separated language codes (all tagging variants) for an ISO code."
  def lang_codes(lang) do
    code = lang |> String.downcase() |> String.trim()
    # Normalize a 639-2 form (jpn/rus/…) back to the 639-1 key so both map.
    key = Enum.find(Map.keys(@lang_aliases), code, fn k -> code in String.split(@lang_aliases[k], ",") end)
    Map.get(@lang_aliases, key, code)
  end

  defp aliases(lang), do: lang_codes(lang)

  def open(app, url, _extra_args) when is_map_key(@gui, app) and is_binary(url) do
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
