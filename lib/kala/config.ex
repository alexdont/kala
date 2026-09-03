defmodule Kala.Config do
  @moduledoc """
  Loads provider tokens and API keys into the app env.

  Sources, in order of precedence:

    1. Environment variables (`RD_TOKEN`, `TMDB_API_KEY`, …)
    2. `~/.config/kala/config` — plain `KEY=VALUE` lines, `#` comments,
       same key names as the environment variables.
  """

  @keys %{
    "RD_TOKEN" => :rd_token,
    "TORBOX_API_KEY" => :torbox_api_key,
    "TMDB_API_KEY" => :tmdb_key,
    "KALA_LANG" => :lang,
    "KALA_SUBS" => :subs_lang,
    "KALA_MPV_ARGS" => :mpv_args,
    "KALA_POSTERS" => :posters,
    "KALA_SKIP" => :skip,
    "KALA_AUTOPLAY" => :autoplay,
    "KALA_DOWNLOAD_DIR" => :download_dir,
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
    Path.join([config_home, "kala", "config"])
  end

  def load do
    file = read_file(path())

    for {env_key, app_key} <- @keys do
      # Back-compat: accept the old KINO_* names too (env or config file),
      # so a config written before the kala rename keeps working.
      old = String.replace_prefix(env_key, "KALA_", "KINO_")

      value =
        System.get_env(env_key) || System.get_env(old) || file[env_key] || file[old]

      if value not in [nil, ""], do: Application.put_env(:kala_app, app_key, value)
    end

    :ok
  end

  @doc "Preferred audio language for source ranking (KALA_LANG), default \"en\"."
  def lang, do: Application.get_env(:kala_app, :lang) || "en"

  @doc """
  Subtitle language (KALA_SUBS): the normalized language code, or `nil` when
  disabled ("off"/"none", any case). Defaults to "en" — deliberately NOT
  KALA_LANG, which is an *audio* ranking preference (a ja-audio fan usually
  still wants English subs unless they say otherwise).
  """
  def subs_lang do
    case Application.get_env(:kala_app, :subs_lang) do
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
  Poster preview style (KALA_POSTERS): "auto" (sharp pixel graphics via the
  terminal's image protocol — the default), "ascii" (colored ASCII glyphs on
  the terminal's own background), "ascii-bg" (ASCII with painted cell
  backgrounds), or "off" (no poster previews).
  """
  def posters do
    case Application.get_env(:kala_app, :posters) do
      value when is_binary(value) -> value |> String.trim() |> String.downcase()
      _ -> "auto"
    end
  end

  @doc """
  Intro/credits skipping (KALA_SKIP): "ask" (default — show a Skip button
  when an intro is detected, skip only on Tab), "auto" (skip immediately),
  or "off". Detection: AniSkip timestamps for anime + named chapters.
  """
  def skip do
    case Application.get_env(:kala_app, :skip) do
      value when is_binary(value) ->
        case value |> String.trim() |> String.downcase() do
          off when off in ["off", "none", "false"] -> "off"
          "auto" -> "auto"
          _ -> "ask"
        end

      _ ->
        "ask"
    end
  end

  @doc """
  Autoplay the next episode when one ends (KALA_AUTOPLAY): "off" by default —
  binge-watching is strictly opt-in ("on" here, `--binge`, or the post-play
  menu's autoplay entry).
  """
  def autoplay? do
    case Application.get_env(:kala_app, :autoplay) do
      value when is_binary(value) ->
        String.downcase(String.trim(value)) in ["on", "true", "yes", "1"]

      _ ->
        false
    end
  end

  @doc "True when the user explicitly set KALA_SUBS."
  def subs_explicit?, do: Application.get_env(:kala_app, :subs_lang) != nil

  @doc "Which keys are configured (by env-var name), for `kala config`."
  def status do
    for {env_key, app_key} <- @keys, into: %{} do
      {env_key, Application.get_env(:kala_app, app_key) not in [nil, ""]}
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
