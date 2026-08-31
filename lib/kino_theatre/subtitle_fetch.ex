defmodule KinoTheatre.SubtitleFetch do
  @moduledoc """
  Fetch an external subtitle file for a title/episode and save it locally so
  a desktop player can load it (`mpv --sub-file=<path>`).

  Anime goes to Jimaku (release-timed JP/EN files, no download quota), with
  OpenSubtitles as the English fallback; everything else goes to
  OpenSubtitles. Files are kept in their native format — mpv renders .srt and
  .ass (with styling) directly, so no VTT conversion is needed.
  """

  alias KinoTheatre.{Jimaku, OpenSubtitles}

  @doc """
  Fetch the best subtitle for the play context in `lang` (ISO 639-1).

  `ctx` needs `:type`, `:title`, `:tmdb_id`; optional `:season`, `:episode`,
  `:anime`, `:search_title` (the release-name title, e.g. romaji for anime).

  Returns `{:ok, path, label}` or `{:error, reason}`.
  """
  def fetch(ctx, lang) do
    anime? = Map.get(ctx, :anime, false)
    query = Map.get(ctx, :search_title) || ctx.title

    cond do
      anime? and lang in ["ja", "en"] and Jimaku.configured?() ->
        case jimaku(query, ctx[:episode], lang) do
          {:ok, _, _} = ok -> ok
          {:error, _} when lang == "en" -> opensubtitles(ctx, query, lang)
          error -> error
        end

      OpenSubtitles.configured?() ->
        opensubtitles(ctx, query, lang)

      true ->
        {:error, :no_provider}
    end
  end

  @doc "True when at least one subtitle provider is configured."
  def available?, do: OpenSubtitles.configured?() or Jimaku.configured?()

  defp jimaku(query, episode, lang) do
    jlang = if lang == "ja", do: :japanese, else: :english

    with {:ok, %{name: name, url: url}} <- Jimaku.subtitle_file(query, episode, jlang),
         {:ok, %{status: 200, body: body}} when is_binary(body) <-
           Req.get(url, receive_timeout: 20_000, decode_body: false) do
      {:ok, save(name, body), "Jimaku · #{name}"}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:jimaku_download, other}}
    end
  end

  defp opensubtitles(ctx, query, lang) do
    cond do
      not OpenSubtitles.configured?() ->
        {:error, :no_provider}

      not OpenSubtitles.can_download?() ->
        {:error, :opensubtitles_needs_login}

      true ->
        opts =
          case ctx.type do
            "tv" ->
              [
                languages: lang,
                query: query,
                season_number: ctx[:season] || 1,
                episode_number: ctx[:episode]
              ]

            "movie" ->
              [languages: lang, query: query, tmdb_id: ctx[:tmdb_id]]
          end

        with {:ok, [best | _]} <- OpenSubtitles.search(opts),
             {:ok, srt} <- OpenSubtitles.download_srt(best.file_id) do
          {:ok, save("#{best.release}.srt", srt), "OpenSubtitles · #{best.release}"}
        else
          {:ok, []} -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:opensubtitles_download, other}}
        end
    end
  end

  # Keep the original extension — mpv picks the subtitle format from it.
  defp save(name, content) do
    ext =
      case Path.extname(String.downcase(name)) do
        e when e in [".srt", ".ass", ".ssa", ".vtt", ".sub"] -> e
        _ -> ".srt"
      end

    dir = Path.join(System.tmp_dir!(), "kino-subs")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{System.os_time(:millisecond)}#{ext}")
    File.write!(path, content)
    path
  end
end
