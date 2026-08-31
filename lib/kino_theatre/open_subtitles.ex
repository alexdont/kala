defmodule KinoTheatre.OpenSubtitles do
  @moduledoc """
  OpenSubtitles.com REST API client — search subtitles in any language and
  fetch the actual .srt text.

  Search needs only an API key; downloading needs a logged-in token (username +
  password), and counts against your daily download quota. Config comes from
  `OPENSUBTITLES_API_KEY`, `OPENSUBTITLES_USERNAME`, `OPENSUBTITLES_PASSWORD`.
  """

  @base "https://api.opensubtitles.com/api/v1"
  @token_key {__MODULE__, :token}

  def configured?, do: api_key() not in [nil, ""]

  def can_download?, do: configured?() and username() not in [nil, ""] and password() not in [nil, ""]

  @doc """
  Search subtitles. `opts` may include `:query`, `:tmdb_id`, `:season_number`,
  `:episode_number`, `:languages` (comma string like "en,es").
  Returns `{:ok, [%{file_id, language, release, downloads}]}` best-first.
  """
  def search(opts) do
    params =
      opts
      |> Keyword.take([:query, :tmdb_id, :season_number, :episode_number, :languages])
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    case Req.get(base_req(), url: "/subtitles", params: params) do
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, data |> Enum.flat_map(&to_subs/1) |> Enum.sort_by(& &1.downloads, :desc)}
      {:ok, %{status: status, body: body}} -> {:error, {:opensubtitles, status, body}}
      {:error, exception} -> {:error, exception}
    end
  end

  @doc "Download a subtitle file's .srt text by its `file_id`."
  def download_srt(file_id) do
    with {:ok, token} <- token(),
         {:ok, link} <- request_link(file_id, token),
         {:ok, %{status: 200, body: srt}} <- Req.get(Req.new(url: link, receive_timeout: 20_000)) do
      {:ok, srt}
    end
  end

  @doc "Convert SRT text to WebVTT (browsers' `<track>` needs VTT, not SRT)."
  def srt_to_vtt(srt) do
    body =
      srt
      |> String.replace("﻿", "")
      |> String.replace("\r\n", "\n")
      # SRT uses comma before milliseconds; VTT uses a dot.
      |> String.replace(~r/(\d{2}:\d{2}:\d{2}),(\d{3})/, "\\1.\\2")

    "WEBVTT\n\n" <> body
  end

  # ── internals ─────────────────────────────────────────────────────

  defp to_subs(%{"attributes" => a}) do
    for f <- a["files"] || [] do
      %{
        file_id: f["file_id"],
        language: a["language"],
        release: a["release"] || f["file_name"],
        downloads: a["download_count"] || 0
      }
    end
  end

  defp request_link(file_id, token) do
    req = Req.new(base_url: @base, headers: auth_headers(token), receive_timeout: 20_000)

    case Req.post(req, url: "/download", json: %{file_id: file_id}) do
      {:ok, %{status: 200, body: %{"link" => link}}} -> {:ok, link}
      {:ok, %{status: status, body: body}} -> {:error, {:opensubtitles_download, status, body}}
      {:error, exception} -> {:error, exception}
    end
  end

  # Cache the login token (valid ~24h) in persistent_term; re-login when stale.
  defp token do
    case :persistent_term.get(@token_key, nil) do
      {token, expires_at} ->
        if System.system_time(:second) < expires_at, do: {:ok, token}, else: login()

      nil ->
        login()
    end
  end

  defp login do
    if can_download?() do
      case Req.post(base_req(), url: "/login", json: %{username: username(), password: password()}) do
        {:ok, %{status: 200, body: %{"token" => token}}} ->
          # Refresh a bit before the ~24h expiry.
          :persistent_term.put(@token_key, {token, System.system_time(:second) + 20 * 3600})
          {:ok, token}

        {:ok, %{status: status, body: body}} ->
          {:error, {:opensubtitles_login, status, body}}

        {:error, exception} ->
          {:error, exception}
      end
    else
      {:error, :opensubtitles_login_not_configured}
    end
  end

  defp base_req, do: Req.new(base_url: @base, headers: base_headers(), receive_timeout: 20_000)

  defp base_headers do
    [
      {"api-key", api_key()},
      {"user-agent", user_agent()},
      {"accept", "application/json"},
      {"content-type", "application/json"}
    ]
  end

  defp auth_headers(token), do: [{"authorization", "Bearer #{token}"} | base_headers()]

  defp api_key, do: Application.get_env(:kino_app, :opensubtitles_api_key)
  defp username, do: Application.get_env(:kino_app, :opensubtitles_username)
  defp password, do: Application.get_env(:kino_app, :opensubtitles_password)
  defp user_agent, do: Application.get_env(:kino_app, :opensubtitles_user_agent) || "kino v1.0"
end
