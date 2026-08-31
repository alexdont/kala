defmodule KinoTheatre.UpdateCheck do
  @moduledoc """
  Checks GitHub's latest release tag against the running version — used by
  the interactive menu only (never by plumbing commands, which must stay
  network-predictable). The result is cached for a few hours so launches
  don't hit GitHub every time, and every failure path degrades to :unknown.
  """

  @repo "alexdont/kino"
  @cache_ttl_s 6 * 3600

  @doc "Returns `{:current, vsn}`, `{:update, current, latest}`, or `:unknown`."
  def status do
    current = current_version()

    case latest_version() do
      nil ->
        :unknown

      latest ->
        case Version.compare(current, latest) do
          :lt -> {:update, current, latest}
          _ -> {:current, current}
        end
    end
  rescue
    _ -> :unknown
  end

  defp current_version, do: Application.spec(:kino_app, :vsn) |> to_string()

  @doc "Latest release version straight from GitHub (no cache), or nil."
  def fetch_latest do
    with version when is_binary(version) <- fetch() do
      write_cache(version)
      version
    end
  end

  @doc "The release-asset name for this machine, or nil when unsupported."
  def asset_name do
    arch = :erlang.system_info(:system_architecture) |> to_string()

    case {:os.type(), arch} do
      {{:unix, :linux}, "x86_64" <> _} -> "kino_linux_x86_64"
      {{:unix, :darwin}, "aarch64" <> _} -> "kino_macos_aarch64"
      {{:unix, :darwin}, "arm" <> _} -> "kino_macos_aarch64"
      _ -> nil
    end
  end

  def download_url(asset), do: "https://github.com/#{@repo}/releases/latest/download/#{asset}"

  defp latest_version do
    case read_cache() do
      {:fresh, latest} ->
        latest

      stale ->
        case fetch() do
          nil ->
            with {:stale, latest} <- stale, do: latest

          latest ->
            write_cache(latest)
            latest
        end
    end
  end

  defp fetch do
    case Req.get("https://api.github.com/repos/#{@repo}/releases/latest",
           receive_timeout: 1500,
           connect_options: [timeout: 1500],
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"tag_name" => "v" <> version}}} -> version
      _ -> nil
    end
  end

  # Cache format: "<unix ts> <version>" in one line.
  defp read_cache do
    with {:ok, body} <- File.read(cache_file()),
         [ts, version] <- String.split(String.trim(body), " ", parts: 2),
         {ts, ""} <- Integer.parse(ts) do
      if System.os_time(:second) - ts < @cache_ttl_s,
        do: {:fresh, version},
        else: {:stale, version}
    else
      _ -> :none
    end
  end

  defp write_cache(version) do
    File.mkdir_p!(Path.dirname(cache_file()))
    File.write(cache_file(), "#{System.os_time(:second)} #{version}")
  end

  defp cache_file do
    dir = Application.get_env(:kino_app, :data_dir) || Path.join(System.user_home!(), ".kino")
    Path.join(dir, "update_check")
  end
end
