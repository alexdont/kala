defmodule KinoTheatre.Torbox do
  @moduledoc """
  TorBox API client — the second debrid provider.

  Same contract as `RD.resolve_magnet/2`: magnet in, playable HTTPS URL out.
  Flow: checkcached (by hash, instant) → createtorrent (instant for cached)
  → pick the video file → requestdl (CDN link). Uncached torrents fail fast
  with `{:not_cached, ...}` — kino's probe philosophy is verified-playable
  only, and TorBox cloud-downloading belongs to an explicit flow, not a probe.
  """

  alias KinoTheatre.FilePick

  @base "https://api.torbox.app/v1/api"

  def configured?, do: token() not in [nil, ""]

  @doc "Magnet in, playable URL out. `{:ok, stream}` or `{:error, reason}`."
  def resolve_magnet(magnet, opts \\ []) do
    episode = Keyword.get(opts, :episode)
    season = Keyword.get(opts, :season)

    with hash when is_binary(hash) <- magnet_hash(magnet) || {:error, :magnet_error},
         :ok <- cached?(hash),
         {:ok, torrent_id} <- create_torrent(magnet),
         {:ok, files} <- await_files(torrent_id),
         {:ok, file} <- FilePick.choose(files, episode, season),
         {:ok, url} <- request_dl(torrent_id, file["id"]) do
      {:ok,
       %{
         url: url,
         download_url: url,
         filename: Path.basename(file["path"]),
         filesize: file["bytes"],
         id: torrent_id,
         streamable: true,
         hls: false,
         provider: :torbox
       }}
    end
  end

  defp magnet_hash(magnet) do
    case Regex.run(~r/btih:([0-9a-fA-F]{40})/, magnet) do
      [_, hash] -> String.downcase(hash)
      _ -> nil
    end
  end

  defp cached?(hash) do
    case get("/torrents/checkcached", params: [hash: hash, format: "object", list_files: false]) do
      {:ok, %{"data" => %{} = data}} when data != %{} ->
        if Map.has_key?(data, hash), do: :ok, else: {:error, {:not_cached, "uncached", 0}}

      {:ok, _} ->
        {:error, {:not_cached, "uncached", 0}}

      error ->
        error
    end
  end

  defp create_torrent(magnet) do
    case Req.post(req(), url: "/torrents/createtorrent", form_multipart: [magnet: magnet]) do
      {:ok, %{status: s, body: %{"success" => true, "data" => %{"torrent_id" => id}}}} when s in 200..299 ->
        {:ok, id}

      other ->
        error(other)
    end
  end

  # Cached torrents surface their file list within a couple of seconds.
  defp await_files(torrent_id, attempts \\ 8)
  defp await_files(_torrent_id, 0), do: {:error, :timeout_waiting_for_files}

  defp await_files(torrent_id, attempts) do
    case get("/torrents/mylist", params: [id: torrent_id, bypass_cache: true]) do
      {:ok, %{"data" => %{"files" => files} = data}} when is_list(files) and files != [] ->
        if data["download_present"] do
          {:ok,
           Enum.map(files, fn f ->
             %{"id" => f["id"], "path" => f["name"] || f["short_name"] || "", "bytes" => f["size"]}
           end)}
        else
          retry_files(torrent_id, attempts)
        end

      {:ok, _} ->
        retry_files(torrent_id, attempts)

      error ->
        error
    end
  end

  defp retry_files(torrent_id, attempts) do
    Process.sleep(1000)
    await_files(torrent_id, attempts - 1)
  end

  # requestdl authenticates via a `token` query param (TorBox quirk — the
  # bearer header alone is rejected for this endpoint).
  defp request_dl(torrent_id, file_id) do
    case get("/torrents/requestdl",
           params: [token: token(), torrent_id: torrent_id, file_id: file_id]
         ) do
      {:ok, %{"success" => true, "data" => url}} when is_binary(url) -> {:ok, url}
      other -> error(other)
    end
  end

  @doc "Remove a torrent from the TorBox account (cleanup for failed probes)."
  def delete_torrent(torrent_id) do
    Req.post(req(),
      url: "/torrents/controltorrent",
      json: %{torrent_id: torrent_id, operation: "delete"}
    )

    :ok
  end

  defp get(path, opts) do
    case Req.get(req(), [url: path] ++ opts) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      other -> error(other)
    end
  end

  defp error({:ok, %{status: status, body: %{"detail" => detail}}}) when is_binary(detail),
    do: {:error, {:torbox, status, detail}}

  defp error({:ok, %{status: status}}), do: {:error, {:torbox, status}}
  defp error({:error, exception}), do: {:error, exception}
  defp error(other), do: {:error, other}

  defp req do
    Req.new(
      base_url: @base,
      auth: {:bearer, token()},
      retry: :transient,
      max_retries: 3,
      retry_log_level: :debug,
      receive_timeout: 30_000
    )
  end

  defp token, do: Application.get_env(:kino_app, :torbox_api_key)
end
