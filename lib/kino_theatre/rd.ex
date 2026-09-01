defmodule KinoTheatre.RD do
  @moduledoc """
  Real-Debrid REST API client.

  Core flow: `resolve_magnet/1` takes a magnet link and returns a direct
  HTTPS stream URL, going through addMagnet -> selectFiles -> unrestrict.
  """

  alias KinoTheatre.FilePick

  @base "https://api.real-debrid.com/rest/1.0"

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
             {:ok, file} <- FilePick.choose(info["files"], episode, season),
             :ok <- select_files(id, [file["id"]]),
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
         {:ok, file} <- FilePick.choose(info["files"], episode, season),
         :ok <- select_files(id, [file["id"]]) do
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
