defmodule KinoTheatre.Doctor do
  @moduledoc """
  Health checks for `kino doctor` and live key validation for `kino setup`.

  Every check returns `{:ok, detail}` or `{:error, detail}` — the CLI owns
  the presentation. Service checks are run concurrently with per-check
  timeouts so a dead service can't hang the whole report.
  """

  @check_timeout 10_000

  # ── live key validation (used by setup) ───────────────────────────

  @doc "Validate a Real-Debrid token against /user. {:ok, \"alexdont · premium · 143 days left\"}."
  def check_rd(token) do
    case Req.get("https://api.real-debrid.com/rest/1.0/user",
           auth: {:bearer, token},
           retry: false,
           receive_timeout: @check_timeout
         ) do
      {:ok, %{status: 200, body: %{"username" => user} = body}} ->
        {:ok, Enum.join([user, body["type"] || "?", days_left(body["expiration"])], " · ")}

      {:ok, %{status: 401}} ->
        {:error, "token rejected (401)"}

      {:ok, %{status: 403}} ->
        {:error, "account locked or not premium (403)"}

      {:ok, %{status: status}} ->
        {:error, "Real-Debrid answered #{status}"}

      {:error, reason} ->
        {:error, "unreachable: #{inspect(reason)}"}
    end
  end

  defp days_left(expiration) when is_binary(expiration) do
    case DateTime.from_iso8601(expiration) do
      {:ok, dt, _} -> "#{div(DateTime.diff(dt, DateTime.utc_now()), 86_400)} days left"
      _ -> "expiry unknown"
    end
  end

  defp days_left(_), do: "expiry unknown"

  @doc "Validate a TorBox API key against /user/me. {:ok, \"essential plan\"}."
  def check_torbox(key) do
    case Req.get("https://api.torbox.app/v1/api/user/me",
           auth: {:bearer, key},
           retry: false,
           receive_timeout: @check_timeout
         ) do
      {:ok, %{status: 200, body: %{"success" => true, "data" => data}}} ->
        {:ok, Enum.join([torbox_plan(data["plan"]), days_left(data["premium_expires_at"])], " · ")}

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, "key rejected (#{status})"}

      {:ok, %{status: status}} ->
        {:error, "TorBox answered #{status}"}

      {:error, reason} ->
        {:error, "unreachable: #{inspect(reason)}"}
    end
  end

  defp torbox_plan(0), do: "free plan"
  defp torbox_plan(1), do: "essential plan"
  defp torbox_plan(2), do: "pro plan"
  defp torbox_plan(3), do: "standard plan"
  defp torbox_plan(_), do: "key accepted"

  @doc "Validate a TMDB key (v3 api_key or v4 bearer) against /configuration."
  def check_tmdb(key) do
    opts = [url: "https://api.themoviedb.org/3/configuration", retry: false, receive_timeout: @check_timeout]

    opts =
      if String.starts_with?(key, "eyJ"),
        do: Keyword.put(opts, :auth, {:bearer, key}),
        else: Keyword.put(opts, :params, api_key: key)

    case Req.get(Req.new(), opts) do
      {:ok, %{status: 200}} -> {:ok, "key accepted"}
      {:ok, %{status: 401}} -> {:error, "key rejected (401)"}
      {:ok, %{status: status}} -> {:error, "TMDB answered #{status}"}
      {:error, reason} -> {:error, "unreachable: #{inspect(reason)}"}
    end
  end

  # ── kino doctor ───────────────────────────────────────────────────

  @doc """
  Run every applicable check concurrently. Returns `{results, healthy?}`:
  results are `{section, name, :ok | :error | :skip, detail}` in display
  order; `healthy?` is false when a required piece is broken.
  """
  def run do
    binaries = [
      {"mpv", :required, "plays the streams"},
      {"fzf", :optional, "interactive pickers"},
      {"chafa", :optional, "poster previews"},
      {"curl", :optional, "kino download + posters"}
    ]

    binary_results =
      for {bin, req, why} <- binaries do
        case System.find_executable(bin) do
          nil when req == :required -> {:binaries, bin, :error, "MISSING — #{why}"}
          nil -> {:binaries, bin, :skip, "not installed (optional — #{why})"}
          path -> {:binaries, bin, :ok, path}
        end
      end

    service_results =
      service_checks()
      |> Task.async_stream(fn {name, fun} -> timed(name, fun) end,
        max_concurrency: 8,
        timeout: @check_timeout + 2_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, _} -> {:services, "check", :error, "timed out"}
      end)

    results = binary_results ++ service_results

    healthy? =
      not Enum.any?(results, fn {_s, _n, status, _d} -> status == :error end)

    {results, healthy?}
  end

  defp service_checks do
    rd_token = Application.get_env(:kino_app, :rd_token)
    tmdb_key = Application.get_env(:kino_app, :tmdb_key)

    keyed = [
      rd_token && {"Real-Debrid", fn -> check_rd(rd_token) end},
      rd_token == nil && {"Real-Debrid", fn -> {:error, "RD_TOKEN not set — run: kino setup"} end},
      tmdb_key && {"TMDB", fn -> check_tmdb(tmdb_key) end},
      tmdb_key == nil && {"TMDB", fn -> {:error, "TMDB_API_KEY not set — run: kino setup"} end}
    ]

    public = [
      {"Torrentio", fn -> ping("https://torrentio.strem.fun/manifest.json") end},
      {"apibay", fn -> ping("https://apibay.org/q.php?q=ubuntu") end},
      {"nyaa", fn -> ping("https://nyaa.si/?page=rss&q=test") end},
      {"AnimeTosho", fn -> ping("https://feed.animetosho.org/json?q=test") end},
      {"Kitsu", fn -> ping("https://kitsu.io/api/edge/anime?page[limit]=1") end},
      {"AniSkip", fn -> ping("https://api.aniskip.com/v2/skip-times/16498/1?types[]=op&episodeLength=0") end}
    ]

    optional = [
      Application.get_env(:kino_app, :torbox_api_key) &&
        {"TorBox",
         fn -> check_torbox(Application.get_env(:kino_app, :torbox_api_key)) end},
      Application.get_env(:kino_app, :opensubtitles_api_key) &&
        {"OpenSubtitles",
         fn ->
           ping("https://api.opensubtitles.com/api/v1/infos/formats",
             headers: [{"api-key", Application.get_env(:kino_app, :opensubtitles_api_key)}]
           )
         end},
      Application.get_env(:kino_app, :jimaku_api_key) &&
        {"Jimaku", fn -> ping("https://jimaku.cc") end},
      Application.get_env(:kino_app, :jackett_url) &&
        {"Jackett", fn -> ping(Application.get_env(:kino_app, :jackett_url)) end}
    ]

    Enum.filter(keyed ++ public ++ optional, &is_tuple/1)
  end

  defp timed(name, fun) do
    {micros, result} = :timer.tc(fun)
    ms = "#{div(micros, 1000)}ms"

    case result do
      {:ok, detail} -> {:services, name, :ok, Enum.join([ms, detail], " · ")}
      {:error, detail} -> {:services, name, :error, detail}
    end
  end

  # NOTE: never put a key in default headers here — a key must only ever go
  # to its own service (passed explicitly via opts by the caller).
  defp ping(url, opts \\ []) do
    case Req.get(url,
           retry: false,
           receive_timeout: @check_timeout,
           headers: [{"user-agent", "kino"}] ++ Keyword.get(opts, :headers, [])
         ) do
      {:ok, %{status: status}} when status in 200..399 -> {:ok, "reachable"}
      {:ok, %{status: status}} -> {:error, "answered #{status}"}
      {:error, reason} -> {:error, "unreachable: #{inspect(reason)}"}
    end
  end
end
