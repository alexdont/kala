defmodule KinoTheatre.Config do
  @moduledoc """
  Loads provider tokens and API keys into the app env.

  Sources, in order of precedence:

    1. Environment variables (`RD_TOKEN`, `TMDB_API_KEY`, …)
    2. `~/.config/kino/config` — plain `KEY=VALUE` lines, `#` comments,
       same key names as the environment variables.
  """

  @keys %{
    "RD_TOKEN" => :rd_token,
    "TMDB_API_KEY" => :tmdb_key,
    "KINO_LANG" => :lang,
    "KINO_SUBS" => :subs_lang,
    "KINO_MPV_ARGS" => :mpv_args,
    "KINO_POSTERS" => :posters,
    "KINO_DOWNLOAD_DIR" => :download_dir,
    "OPENSUBTITLES_API_KEY" => :opensubtitles_api_key,
    "OPENSUBTITLES_USERNAME" => :opensubtitles_username,
    "OPENSUBTITLES_PASSWORD" => :opensubtitles_password,
    "JACKETT_URL" => :jackett_url,
    "JACKETT_API_KEY" => :jackett_api_key,
    "JACKETT_INDEXER" => :jackett_indexer,
    "JIMAKU_API_KEY" => :jimaku_api_key
  }

  def path do
    config_home = System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")
    Path.join([config_home, "kino", "config"])
  end

  def load do
    file = read_file(path())

    for {env_key, app_key} <- @keys do
      value = System.get_env(env_key) || file[env_key]
      if value not in [nil, ""], do: Application.put_env(:kino_app, app_key, value)
    end

    :ok
  end

  @doc "Preferred audio language for source ranking (KINO_LANG), default \"en\"."
  def lang, do: Application.get_env(:kino_app, :lang) || "en"

  @doc """
  Subtitle language (KINO_SUBS): the normalized language code, or `nil` when
  disabled ("off"/"none", any case). Defaults to "en" — deliberately NOT
  KINO_LANG, which is an *audio* ranking preference (a ja-audio fan usually
  still wants English subs unless they say otherwise).
  """
  def subs_lang do
    case Application.get_env(:kino_app, :subs_lang) do
      nil ->
        "en"

      value ->
        case value |> String.trim() |> String.downcase() do
          off when off in ["off", "none", ""] -> nil
          lang -> lang
        end
    end
  end

  @doc """
  Poster preview style (KINO_POSTERS): "auto" (sharp pixel graphics via the
  terminal's image protocol — the default), "ascii" (colored ASCII glyphs on
  the terminal's own background), "ascii-bg" (ASCII with painted cell
  backgrounds), or "off" (no poster previews).
  """
  def posters do
    case Application.get_env(:kino_app, :posters) do
      value when is_binary(value) -> value |> String.trim() |> String.downcase()
      _ -> "auto"
    end
  end

  @doc "True when the user explicitly set KINO_SUBS."
  def subs_explicit?, do: Application.get_env(:kino_app, :subs_lang) != nil

  @doc "Which keys are configured (by env-var name), for `kino config`."
  def status do
    for {env_key, app_key} <- @keys, into: %{} do
      {env_key, Application.get_env(:kino_app, app_key) not in [nil, ""]}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        for line <- String.split(contents, "\n"),
            line = String.trim(line),
            line != "" and not String.starts_with?(line, "#"),
            [key, value] <- [String.split(line, "=", parts: 2)],
            into: %{} do
          {String.trim(key), String.trim(value)}
        end

      {:error, _} ->
        %{}
    end
  end
end
