defmodule Kala.SubtitleFetch do
  @moduledoc """
  Fetch an external subtitle file for a title/episode and save it locally so
  a desktop player can load it (`mpv --sub-file=<path>`).

  Anime goes to Jimaku (release-timed JP/EN files, no download quota), with
  OpenSubtitles as the English fallback; everything else goes to
  OpenSubtitles. Files are kept in their native format — mpv renders .srt and
  .ass (with styling) directly, so no VTT conversion is needed.

  Files are cached on disk under deterministic names, so replaying a title
  never re-downloads (OpenSubtitles has a small daily download quota); stale
  cache entries are pruned. Fetching is best-effort by contract: any
  exception is caught and returned as an error — a subtitle problem must
  never break playback.
  """

  alias Kala.{Jimaku, OpenSubtitles}

  @cache_max_age_s 30 * 24 * 3600

  @doc """
  Fetch the best subtitle for the play context in `lang` (ISO 639-1).

  `ctx` needs `:type`, `:title`, `:tmdb_id`; optional `:season`, `:episode`,
  `:anime`, `:search_title` (the release-name title, e.g. romaji for anime).

  Returns `{:ok, path, label}`, `{:error, :no_provider}` when nothing is
  configured for this content, or `{:error, reason}`.
  """
  def fetch(ctx, lang) do
    do_fetch(ctx, lang)
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp do_fetch(ctx, lang) do
    anime? = Map.get(ctx, :anime, false)
    query = Map.get(ctx, :search_title) || ctx.title

    cond do
      anime? and lang in ["ja", "en"] and Jimaku.configured?() ->
        case jimaku(query, ctx[:episode], lang) do
          {:ok, _, _} = ok ->
            ok

          {:error, reason} when lang == "en" ->
            # Fall back to OpenSubtitles, but keep Jimaku's reason if that
            # fails too — ":no_provider" would hide what actually happened.
            with {:error, _} <- opensubtitles(ctx, query, lang), do: {:error, reason}

          error ->
            error
        end

      OpenSubtitles.configured?() ->
        opensubtitles(ctx, query, lang)

      true ->
        {:error, :no_provider}
    end
  end

  defp jimaku(query, episode, lang) do
    jlang = if lang == "ja", do: :japanese, else: :english

    with {:ok, %{name: name, url: url} = file} <- Jimaku.subtitle_file(query, episode, jlang) do
      path = cache_path("jimaku-#{slug(name)}", name)
      label = "Jimaku · #{name}"

      cond do
        File.exists?(path) ->
          {:ok, path, label}

        # The English picker already downloaded the body to verify language.
        is_binary(file[:body]) ->
          {:ok, save(path, file.body), label}

        true ->
          case Req.get(url,
                 receive_timeout: 20_000,
                 decode_body: false,
                 retry: :transient,
                 max_retries: 1
               ) do
            {:ok, %{status: 200, body: body}} when is_binary(body) ->
              {:ok, save(path, body), label}

            other ->
              {:error, {:jimaku_download, other}}
          end
      end
    end
  end

  defp opensubtitles(ctx, query, lang) do
    cond do
      not OpenSubtitles.configured?() ->
        {:error, :no_provider}

      not OpenSubtitles.can_download?() ->
        {:error, :opensubtitles_needs_login}

      true ->
        # For anime, :season is nil on purpose (absolute numbering) — omit it
        # rather than inventing season 1; search/1 drops nil params.
        opts =
          case ctx[:type] do
            "tv" ->
              [
                languages: lang,
                query: query,
                season_number: ctx[:season],
                episode_number: ctx[:episode]
              ]

            _ ->
              [languages: lang, query: query, tmdb_id: ctx[:tmdb_id]]
          end

        with {:ok, [best | _]} <- OpenSubtitles.search(opts) do
          path = cache_path("os-#{best.file_id}", "#{best.release}.srt")
          label = "OpenSubtitles · #{best.release}"

          if File.exists?(path) do
            {:ok, path, label}
          else
            with {:ok, srt} <- OpenSubtitles.download_srt(best.file_id) do
              {:ok, save(path, srt), label}
            end
          end
        else
          {:ok, []} -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # ── on-disk cache ─────────────────────────────────────────────────

  # Deterministic path in the cache dir, keeping the original extension so
  # mpv picks the subtitle format from it.
  defp cache_path(base, original_name) do
    ext =
      case Path.extname(String.downcase(original_name)) do
        e when e != "" ->
          if e in Kala.Subtitles.extensions(), do: e, else: ".srt"

        _ ->
          ".srt"
      end

    dir = Path.join(System.tmp_dir!(), "kala-subs")
    File.mkdir_p!(dir)
    prune(dir)
    Path.join(dir, base <> ext)
  end

  defp save(path, content) do
    File.write!(path, content)
    path
  end

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.slice(0, 80)
  end

  defp prune(dir) do
    cutoff = System.os_time(:second) - @cache_max_age_s

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
end
