defmodule KinoTheatre.RD do
  @moduledoc """
  Real-Debrid REST API client.

  Core flow: `resolve_magnet/1` takes a magnet link and returns a direct
  HTTPS stream URL, going through addMagnet -> selectFiles -> unrestrict.
  """

  @base "https://api.real-debrid.com/rest/1.0"
  @video_exts ~w(.mkv .mp4 .avi .m4v .ts .webm .mov .ogv)

  def configured?, do: token() not in [nil, ""]

  def add_magnet(magnet) do
    post("/torrents/addMagnet", magnet: magnet)
  end

  def torrent_info(id) do
    case Req.get(req(), url: "/torrents/info/#{id}") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      other -> error(other)
    end
  end

  def select_files(id, file_ids) do
    case Req.post(req(), url: "/torrents/selectFiles/#{id}", form: [files: Enum.join(file_ids, ",")]) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      other -> error(other)
    end
  end

  def unrestrict(link) do
    post("/unrestrict/link", link: link)
  end

  def delete_torrent(id) do
    Req.delete(req(), url: "/torrents/delete/#{id}")
    :ok
  end

  @doc """
  Torrents already downloaded in the user's account whose filename contains
  every word of `query` — instant, guaranteed-playable sources (the same trick
  DMM-style Stremio addons use to surface "definite" streams).
  """
  def library(query) do
    case Req.get(req(), url: "/torrents", params: [limit: 100]) do
      {:ok, %{status: 200, body: torrents}} when is_list(torrents) ->
        tokens = tokenize(query)

        torrents
        |> Enum.filter(fn t ->
          t["status"] == "downloaded" and matches_tokens?(t["filename"], tokens)
        end)
        |> Enum.map(fn t ->
          %{name: t["filename"], hash: String.downcase(t["hash"] || ""), size: t["bytes"] || 0}
        end)
        |> Enum.reject(&(&1.hash == ""))

      _ ->
        []
    end
  end

  defp tokenize(str) do
    str |> String.downcase() |> String.split(~r/[^a-z0-9]+/, trim: true)
  end

  defp matches_tokens?(filename, tokens) do
    words = tokenize(filename || "")
    tokens != [] and Enum.all?(tokens, &(&1 in words))
  end

  @doc """
  Magnet in, playable URL out.

  Returns `{:ok, %{url: url, filename: name, filesize: bytes}}` when the
  torrent is cached on RD (near-instant), or `{:error, {:not_cached, status, progress}}`
  when RD has started downloading it server-side (it will be available later),
  or `{:error, reason}` for API failures.
  """
  def resolve_magnet(magnet, opts \\ []) do
    patience = Keyword.get(opts, :patience, 12)
    episode = Keyword.get(opts, :episode)
    season = Keyword.get(opts, :season)

    with {:ok, %{"id" => id}} <- add_magnet(magnet) do
      result =
        with {:ok, info} <- await_file_list(id),
             {:ok, file_ids} <- pick_video_files(info, episode, season),
             :ok <- select_files(id, file_ids),
             {:ok, %{"links" => [link | _]}} <- await_links(id, patience),
             {:ok, unrestricted} <- unrestrict(link) do
          {:ok, stream_from(unrestricted)}
        end

      # Leave successful torrents in the account; clean up the ones that
      # failed (not cached, infringing, no video) so it doesn't pile up.
      with {:error, _reason} <- result do
        delete_torrent(id)
        result
      end
    end
  end

  defp stream_from(u) do
    %{
      url: u["download"],
      download_url: u["download"],
      filename: u["filename"],
      filesize: u["filesize"],
      id: u["id"],
      streamable: u["streamable"] == 1,
      hls: false
    }
  end

  @doc """
  Download a source on Real-Debrid (for non-cached torrents), fetching only the
  requested episode file — not the whole batch — and reporting progress through
  `opts[:notify]` as `{:progress, percent, status, speed}`. Blocks (polling)
  until RD finishes, then returns `{:ok, stream}`. Instant for cached torrents.

  `opts`: `:episode` (file to select from a batch), `:notify`, `:max_wait_ms`.
  """
  def download_magnet(magnet, opts \\ []) do
    episode = Keyword.get(opts, :episode)
    season = Keyword.get(opts, :season)
    notify = Keyword.get(opts, :notify, fn _ -> :ok end)
    max_wait = Keyword.get(opts, :max_wait_ms, 20 * 60 * 1000)

    with {:ok, %{"id" => id}} <- add_magnet(magnet),
         {:ok, info} <- await_file_list(id),
         {:ok, file_ids} <- pick_video_files(info, episode, season),
         :ok <- select_files(id, file_ids) do
      poll_download(id, notify, max_wait, System.monotonic_time(:millisecond))
    end
  end

  defp poll_download(id, notify, max_wait, started) do
    case torrent_info(id) do
      {:ok, %{"status" => "downloaded", "links" => [link | _]}} ->
        with {:ok, unrestricted} <- unrestrict(link), do: {:ok, stream_from(unrestricted)}

      {:ok, %{"status" => status} = info} when status in ~w(downloading queued compressing uploading magnet_conversion) ->
        elapsed = System.monotonic_time(:millisecond) - started
        progress = info["progress"] || 0
        seeders = info["seeders"] || 0

        cond do
          elapsed > max_wait ->
            delete_torrent(id)
            {:error, {:download_timeout, progress}}

          # No seeders and no progress after a grace period: the torrent is dead,
          # RD will just sit at 0% then flip to "error". Bail early with a clear reason.
          seeders == 0 and progress == 0 and elapsed > 25_000 ->
            delete_torrent(id)
            {:error, :no_seeders}

          true ->
            notify.({:progress, progress, status, info["speed"] || 0})
            Process.sleep(2000)
            poll_download(id, notify, max_wait, started)
        end

      {:ok, %{"status" => "waiting_files_selection"}} ->
        Process.sleep(1000)
        poll_download(id, notify, max_wait, started)

      # Terminal failure. RD marks a torrent "error"/"dead" when it can't fetch
      # it — almost always because nothing is seeding it. Say so plainly.
      {:ok, %{"status" => status} = info} ->
        delete_torrent(id)
        if status in ~w(error dead) and (info["seeders"] || 0) == 0,
          do: {:error, :no_seeders},
          else: {:error, {:torrent_status, status}}

      error ->
        error
    end
  end

  @doc """
  Try a ranked list of sources and return the first that actually plays.

  Skips hashes already known-bad (`Blocklist`), records new DMCA (451)
  takedowns as it hits them, and reports progress through `opts[:notify]`
  (a 1-arg function receiving `{:trying, name}` / `{:skipped, name, reason}`).

  Each source is given a shorter cache-wait than a direct play, so a run of
  non-cached sources fails fast instead of stalling on each one.

  Returns `{:ok, stream, source, skipped}` or `{:error, {:all_failed, skipped}}`.
  """
  def resolve_best(sources, opts \\ []) do
    notify = Keyword.get(opts, :notify, fn _ -> :ok end)
    resolve_opts = [patience: 5] ++ Keyword.take(opts, [:episode, :season])
    do_resolve_best(sources, notify, resolve_opts, [])
  end

  @doc """
  Concurrently resolve a batch of `{source, index}` tuples, reporting each
  outcome through `opts[:notify]` as
  `{:result, index, source, {:ok, stream} | {:error, reason}}`.

  This is how the UI shows only playable sources: every source is actually
  resolved on RD, so a `{:ok, stream}` result is ready to play instantly.
  Known-blocked hashes are reported without touching RD; fresh 451s are
  recorded in the `Blocklist`. Returns `:ok` once the whole batch finishes.
  """
  def probe_sources(indexed_sources, opts \\ []) do
    notify = Keyword.get(opts, :notify, fn _ -> :ok end)
    episode = Keyword.get(opts, :episode)
    season = Keyword.get(opts, :season)

    indexed_sources
    |> Task.async_stream(
      fn {source, index} ->
        result =
          if KinoTheatre.Blocklist.blocked?(source.hash) do
            {:error, :known_blocked}
          else
            case resolve_magnet(source.magnet, patience: 5, episode: episode, season: season) do
              {:ok, stream} ->
                {:ok, stream}

              {:error, {:rd, 451, _}} = err ->
                KinoTheatre.Blocklist.block(source.hash)
                err

              other ->
                other
            end
          end

        notify.({:result, index, source, result})
      end,
      max_concurrency: 2,
      ordered: false,
      timeout: 120_000,
      on_timeout: :kill_task
    )
    |> Stream.run()

    :ok
  end

  defp do_resolve_best([], _notify, _resolve_opts, skipped),
    do: {:error, {:all_failed, Enum.reverse(skipped)}}

  defp do_resolve_best([source | rest], notify, resolve_opts, skipped) do
    cond do
      KinoTheatre.Blocklist.blocked?(source.hash) ->
        notify.({:skipped, source.name, :known_blocked})
        do_resolve_best(rest, notify, resolve_opts, [{source.name, :known_blocked} | skipped])

      true ->
        notify.({:trying, source.name})

        case resolve_magnet(source.magnet, resolve_opts) do
          {:ok, stream} ->
            {:ok, stream, source, Enum.reverse(skipped)}

          {:error, {:rd, 451, _}} ->
            KinoTheatre.Blocklist.block(source.hash)
            notify.({:skipped, source.name, :infringing})
            do_resolve_best(rest, notify, resolve_opts, [{source.name, :infringing} | skipped])

          {:error, reason} ->
            notify.({:skipped, source.name, reason})
            do_resolve_best(rest, notify, resolve_opts, [{source.name, reason} | skipped])
        end
    end
  end

  @doc """
  HLS transcode URL (AAC audio) for an unrestricted download id.

  This is the fix for releases whose audio the browser can't decode
  (DTS, TrueHD, AC3): RD re-muxes to HLS and transcodes audio to AAC.
  """
  def transcode_hls(download_id) do
    case Req.get(req(), url: "/streaming/transcode/#{download_id}") do
      {:ok, %{status: 200, body: %{"apple" => %{"full" => url}}}} -> {:ok, url}
      {:ok, %{status: 200, body: body}} -> {:error, {:no_hls_variant, Map.keys(body)}}
      other -> error(other)
    end
  end

  # RD needs a moment after addMagnet before the file list is available.
  defp await_file_list(id, attempts \\ 10)
  defp await_file_list(_id, 0), do: {:error, :timeout_waiting_for_files}

  defp await_file_list(id, attempts) do
    case torrent_info(id) do
      {:ok, %{"status" => "waiting_files_selection"} = info} -> {:ok, info}
      {:ok, %{"status" => "magnet_error"}} -> {:error, :magnet_error}
      # Already selected on a previous attempt (RD dedupes torrents per account)
      {:ok, %{"status" => status} = info} when status in ~w(downloaded downloading queued) -> {:ok, info}
      {:ok, _info} -> retry_file_list(id, attempts)
      error -> error
    end
  end

  defp retry_file_list(id, attempts) do
    Process.sleep(1000)
    await_file_list(id, attempts - 1)
  end

  defp pick_video_files(%{"id" => _, "files" => files}, episode, season) when is_list(files) and files != [] do
    videos = Enum.filter(files, fn f -> Path.extname(String.downcase(f["path"])) in @video_exts end)

    case videos do
      [] ->
        {:error, :no_video_files}

      [only] ->
        {:ok, [only["id"]]}

      many ->
        # Batch/season pack: pick the file for the requested episode; otherwise
        # (single-episode releases, or no match) fall back to the largest file.
        chosen =
          (episode && pick_episode_file(many, episode, season)) ||
            Enum.max_by(many, & &1["bytes"])

        {:ok, [chosen["id"]]}
    end
  end

  defp pick_video_files(_info, _episode, _season), do: {:error, :no_video_files}

  # Choose the file for a given episode. When the season is known (live-action
  # TV), require an exact SxxExx match first so a multi-season pack can't grab the
  # same episode number from the wrong season; fall back to a looser episode-only
  # match (anime absolute numbering, single-season packs).
  defp pick_episode_file(files, episode, season) do
    (season && Enum.find(files, &sxxexx_file?(&1["path"], season, episode))) ||
      Enum.find(files, &episode_file?(&1["path"], episode))
  end

  # Exact SxxExx (season + episode), e.g. "Lupin.S01E01." — the (?![0-9]) stops
  # E1 from matching E11/E1x.
  defp sxxexx_file?(path, season, episode) do
    Regex.match?(~r/s0*#{season}e0*#{episode}(?![0-9])/i, Path.basename(path))
  end

  # Does this filename correspond to the given episode number? Tokenize and look
  # for the number as a standalone token (or E24 / S01E24), so "GTO - 24" matches
  # but "GTO 2024"/"1080p" don't.
  defp episode_file?(path, episode) do
    ep = Integer.to_string(episode)
    padded = String.pad_leading(ep, 2, "0")

    path
    |> Path.basename()
    |> String.downcase()
    |> then(&Regex.split(~r/[\s_\-.\[\]()]+/, &1))
    |> Enum.any?(fn tok ->
      tok in [ep, padded, "e#{ep}", "e#{padded}"] or Regex.match?(~r/^s\d+e0*#{episode}$/, tok)
    end)
  end

  # Cached torrents flip to "downloaded" within a couple of seconds.
  defp await_links(_id, 0), do: {:error, :timeout_waiting_for_links}

  defp await_links(id, attempts) do
    case torrent_info(id) do
      {:ok, %{"status" => "downloaded"} = info} ->
        {:ok, info}

      {:ok, %{"status" => status, "progress" => progress}} when status in ~w(downloading queued) ->
        if attempts <= 1 do
          {:error, {:not_cached, status, progress}}
        else
          Process.sleep(1000)
          await_links(id, attempts - 1)
        end

      {:ok, %{"status" => status}} ->
        {:error, {:torrent_status, status}}

      error ->
        error
    end
  end

  defp post(path, form) do
    case Req.post(req(), url: path, form: form) do
      {:ok, %{status: s, body: body}} when s in 200..299 -> {:ok, body}
      other -> error(other)
    end
  end

  defp error({:ok, %{status: status, body: %{"error" => error}}}), do: {:error, {:rd, status, error}}
  defp error({:ok, %{status: status}}), do: {:error, {:rd, status}}
  defp error({:error, exception}), do: {:error, exception}

  defp req do
    # :transient retries 408/429/5xx with exponential backoff, honoring
    # RD's Retry-After header — important when probing sources concurrently.
    # Retries are logged at debug only: 429s are routine while probing and
    # the warnings would drown the CLI's own progress output.
    Req.new(
      base_url: @base,
      auth: {:bearer, token()},
      retry: :transient,
      max_retries: 6,
      retry_log_level: :debug,
      receive_timeout: 30_000
    )
  end

  defp token, do: Application.get_env(:kino_app, :rd_token)
end
