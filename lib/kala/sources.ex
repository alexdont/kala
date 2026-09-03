defmodule Kala.Sources do
  @moduledoc """
  Torrent source discovery. Two backends feed a common source struct:

    * `:apibay` — ThePirateBay JSON API, for movies and live-action TV.
    * `:nyaa`   — Nyaa.si RSS, where practically all anime torrents live
                  (fansub-group releases with absolute episode numbers).

  Both go through the same release-name parsing, ranking, and magnet building,
  so the rest of the app (probe / resolve / play) doesn't care which found it.
  """

  @apibay "https://apibay.org/q.php"
  @nyaa "https://nyaa.si/"
  @animetosho "https://feed.animetosho.org/json"
  @torrentio "https://torrentio.strem.fun"
  @empty_hash "0000000000000000000000000000000000000000"

  @trackers [
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.demonii.com:1337/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://exodus.desync.com:6969/announce"
  ]

  @doc """
  Search for torrents. `opts[:backend]` is `:apibay` (default) or `:nyaa`.
  Returns `{:ok, [source]}` sorted best-first.
  """
  def search(query, opts \\ []) do
    indexers =
      case Keyword.get(opts, :backend, :apibay) do
        :anime -> [fn -> search_nyaa(query) end, fn -> search_animetosho(query) end]
        :apibay -> [fn -> search_apibay(query) end]
        :nyaa -> [fn -> search_nyaa(query) end]
      end

    # Jackett/Prowlarr (Torznab) augments every context when configured — it
    # fronts dozens of indexers, so it helps both anime and movie/TV coverage.
    # Torrentio (public, no key) aggregates many public trackers by IMDb id — a
    # big coverage boost for movies/TV — added when `opts[:torrentio]` is given.
    indexers = indexers ++ torznab_indexer(query) ++ torrentio_indexer(opts)

    merge_search(indexers)
  end

  @doc "True when a Jackett/Prowlarr Torznab endpoint is configured."
  def torznab_configured?, do: jackett_url() not in [nil, ""] and jackett_key() not in [nil, ""]

  defp torznab_indexer(query) do
    if torznab_configured?(), do: [fn -> search_torznab(query) end], else: []
  end

  # Torrentio needs the IMDb id (+ season/episode for TV), not a text query — so
  # it's requested via `opts[:torrentio]` rather than the query string.
  defp torrentio_indexer(opts) do
    case Keyword.get(opts, :torrentio) do
      {:movie, imdb} when is_binary(imdb) -> [fn -> torrentio_movie(imdb) end]
      {:series, imdb, s, e} when is_binary(imdb) -> [fn -> torrentio_series(imdb, s, e) end]
      _ -> []
    end
  end

  # Run indexers concurrently, merge, dedup by infohash keeping the best-scored
  # copy. As long as one indexer answers we return its (possibly empty) results;
  # only error if every indexer failed. More distinct hashes = better odds one
  # is cached & un-DMCA'd on Real-Debrid.
  defp merge_search(indexers) do
    {oks, errors} =
      indexers
      |> Enum.map(&Task.async/1)
      |> Task.await_many(25_000)
      |> Enum.split_with(&match?({:ok, _}, &1))

    case oks do
      [] ->
        Enum.at(errors, 0, {:error, :no_sources})

      _ ->
        oks
        |> Enum.flat_map(fn {:ok, list} -> list end)
        |> Enum.sort_by(&score/1, :desc)
        |> Enum.uniq_by(& &1.hash)
        |> then(&{:ok, &1})
    end
  end

  # ── query builders ────────────────────────────────────────────────

  @doc "Query for a live-action TV episode: `Title S01E02`."
  def episode_query(show_title, season, episode) do
    "#{show_title} S#{pad(season)}E#{pad(episode)}"
  end

  @doc """
  Query for an anime episode. Nyaa releases use absolute episode numbers and
  fansub naming (`[SubsPlease] Frieren - 12`), so we drop any `:` subtitle and
  append the (zero-padded) episode number as a plain search term.
  """
  def anime_episode_query(title, episode) do
    "#{anime_title(title)} #{pad(episode)}"
  end

  @doc "Query for an anime movie — just the cleaned title."
  def anime_movie_query(title), do: anime_title(title)

  @doc """
  Search for an anime episode, combining per-episode releases *and* whole-series
  batch/season packs (older shows like GTO exist mostly as batches). Per-episode
  results rank first (exact file); batches follow (RD selects the episode file).
  Deduped by infohash.

  Returns `{:ok, sources, :episode | :series | :mixed}`.
  """
  def anime_episode_search(title, episode, opts \\ []) do
    # Torrentio by Kitsu id runs alongside the Nyaa/AnimeTosho search — it's
    # the only anime path that reaches the big public/Russian trackers.
    torrentio =
      Task.async(fn ->
        case torrentio_anime(Keyword.get(opts, :kitsu_id), episode) do
          {:ok, list} -> list
          _ -> []
        end
      end)

    {base, scope} =
      case Keyword.get(opts, :anidb_id) do
        nil ->
          case text_episode_search(title, episode) do
            {:ok, sources, scope} -> {sources, scope}
            _ -> {[], :episode}
          end

        aid ->
          # Exact-show results by AniDB id; episode-specific first, then batches.
          case search_animetosho_aid(aid) do
            {:ok, all} when all != [] ->
              {ep, rest} = Enum.split_with(all, &release_has_episode?(&1.name, episode))
              {Enum.sort_by(ep, &score/1, :desc) ++ Enum.sort_by(rest, &score/1, :desc), :mixed}

            _ ->
              case text_episode_search(title, episode) do
                {:ok, sources, scope} -> {sources, scope}
                _ -> {[], :episode}
              end
          end
      end

    tor = Task.await(torrentio, 25_000)

    sources =
      (tor ++ base)
      |> Enum.filter(&anime_release_ok?(&1.name, episode, Keyword.get(opts, :search_title)))
      |> Enum.sort_by(&score/1, :desc)
      |> Enum.uniq_by(& &1.hash)
      |> Enum.take(40)

    {:ok, sources, scope}
  end

  # Reject releases that clearly belong to a different season or a different
  # single episode than the one being watched — the fuzzy title search and
  # even id-scoped feeds occasionally leak franchise-wide.
  defp anime_release_ok?(name, episode, search_title) do
    wanted = wanted_season(search_title)

    season_ok? =
      case Regex.run(~r/\bs(?:eason)?\s*0*(\d+)\s*e/i, name) || Regex.run(~r/\bs0*(\d+)\b/i, name) do
        [_, s] -> String.to_integer(s) == wanted
        _ -> true
      end

    # A batch/range (contains the episode, RD extracts it) or a release that
    # names *this* episode is fine; a single release naming a *different*
    # episode is not.
    episode_ok? = batch?(name) or release_has_episode?(name, episode) or not names_single_episode?(name)

    season_ok? and episode_ok?
  end

  # Season number implied by the picked entry's title ("2nd Season" → 2,
  # "Season 3"/"3rd Season" → 3); base entries and movies are season 1.
  defp wanted_season(nil), do: 1

  defp wanted_season(title) do
    cond do
      m = Regex.run(~r/\bseason\s*(\d+)\b/i, title) -> String.to_integer(Enum.at(m, 1))
      m = Regex.run(~r/\b(\d+)(?:st|nd|rd|th)\s+season\b/i, title) -> String.to_integer(Enum.at(m, 1))
      true -> 1
    end
  end

  defp batch?(name) do
    Regex.match?(~r/\bbatch|complete|\bseason\b|\bS\d+\b(?!E)|\d+\s*[-~]\s*\d+|\bvol\b/i, name)
  end

  # Does the name pin a single episode number (E12 / - 12 / _12_) at all?
  defp names_single_episode?(name) do
    Regex.match?(~r/\be\d{1,3}\b|(?:^|[\s_\-\[])\d{1,3}(?:$|[\s_\-\]v])/i, name)
  end

  defp text_episode_search(title, episode) do
    episode_result = search(anime_episode_query(title, episode), backend: :anime)
    series_result = search(anime_movie_query(title), backend: :anime)

    case {episode_result, series_result} do
      {{:ok, ep}, {:ok, series}} ->
        merged = (ep ++ series) |> Enum.uniq_by(& &1.hash) |> Enum.take(30)
        scope = cond do
          ep == [] -> :series
          series == [] -> :episode
          true -> :mixed
        end

        {:ok, merged, scope}

      {{:ok, ep}, _} -> {:ok, ep, :episode}
      {_, {:ok, series}} -> {:ok, series, :series}
      {error, _} -> error
    end
  end

  # Does the release name mention this episode number as a standalone token
  # ("SAO - 01" yes; "S01" batch or "2012" no)?
  defp release_has_episode?(name, episode) do
    ep = Integer.to_string(episode)
    padded = String.pad_leading(ep, 2, "0")

    name
    |> String.downcase()
    |> then(&Regex.split(~r/[\s_\-.\[\]()]+/, &1))
    |> Enum.any?(fn tok ->
      tok in [ep, padded, "e#{ep}", "e#{padded}"] or Regex.match?(~r/^s\d+e0*#{episode}$/, tok)
    end)
  end

  defp anime_title(title) do
    title
    |> String.split(":", parts: 2)
    |> hd()
    |> String.trim()
  end

  # ── apibay (movies / live-action TV) ──────────────────────────────

  defp search_apibay(query) do
    case Req.get(Req.new(url: @apibay, params: [q: query], retry: false, receive_timeout: 15_000)) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok,
         body
         |> Enum.reject(&(&1["info_hash"] == @empty_hash))
         |> Enum.map(fn t ->
           build_source(%{
             name: t["name"],
             provider: "ThePirateBay",
             hash: t["info_hash"],
             seeders: to_int(t["seeders"]),
             size: to_int(t["size"])
           })
         end)
         |> Enum.sort_by(&score/1, :desc)}

      {:ok, %{status: status}} ->
        {:error, {:apibay, status}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  # ── nyaa (anime) ──────────────────────────────────────────────────

  defp search_nyaa(query) do
    # c=1_2 is "Anime - English-translated"; sort by seeders server-side.
    params = [page: "rss", q: query, c: "1_2", f: "0", s: "seeders", o: "desc"]

    case Req.get(Req.new(url: @nyaa, params: params, retry: false, receive_timeout: 15_000)) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body |> parse_nyaa_rss() |> Enum.sort_by(&score/1, :desc)}

      {:ok, %{status: status}} ->
        {:error, {:nyaa, status}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  # Nyaa's RSS is small and regular; pull each item's fields directly rather
  # than take on an XML dependency. infoHash/seeders/size live in the
  # `nyaa:` namespace.
  defp parse_nyaa_rss(xml) do
    ~r/<item>(.*?)<\/item>/s
    |> Regex.scan(xml, capture: :all_but_first)
    |> Enum.map(fn [item] ->
      %{
        name: item |> field(~r{<title>(.*?)</title>}s) |> unescape(),
        provider: "Nyaa",
        hash: field(item, ~r{<nyaa:infoHash>(.*?)</nyaa:infoHash>}s),
        seeders: item |> field(~r{<nyaa:seeders>(.*?)</nyaa:seeders>}s) |> to_int(),
        size: item |> field(~r{<nyaa:size>(.*?)</nyaa:size>}s) |> parse_size()
      }
    end)
    |> Enum.reject(&(&1.hash == ""))
    |> Enum.map(&build_source/1)
  end

  # ── animetosho (anime, JSON; aggregates Nyaa + other trackers) ────

  defp search_animetosho(query), do: fetch_animetosho(q: query, only_tor: 1)

  # Query AnimeTosho by AniDB anime id — returns only the *exact* show's
  # releases (no same-name spinoffs), the way Stremio/Torrentio do it.
  defp search_animetosho_aid(aid), do: fetch_animetosho(aid: aid, only_tor: 1)

  defp fetch_animetosho(params) do
    req = Req.new(url: @animetosho, params: params, retry: false, receive_timeout: 15_000)

    case Req.get(req) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok,
         body
         |> Enum.filter(&valid_hash?/1)
         |> Enum.map(fn t ->
           build_source(%{
             name: t["title"] || t["torrent_name"],
             provider: "AnimeTosho",
             hash: t["info_hash"],
             seeders: to_int(t["seeders"]),
             size: to_int(t["total_size"])
           })
         end)}

      {:ok, %{status: status}} ->
        {:error, {:animetosho, status}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp valid_hash?(%{"info_hash" => hash}) when is_binary(hash), do: byte_size(hash) == 40
  defp valid_hash?(_), do: false

  # ── torrentio (public aggregator; fronts many trackers, keyed by IMDb id) ──

  @doc "Torrentio sources for a movie, by IMDb id (e.g. \"tt2364582\")."
  def torrentio_movie(imdb_id), do: fetch_torrentio("movie/#{imdb_id}")

  @doc "Torrentio sources for a TV episode, by IMDb id + season + episode."
  def torrentio_series(imdb_id, season, episode), do: fetch_torrentio("series/#{imdb_id}:#{season}:#{episode}")

  @doc """
  Torrentio anime sources by Kitsu id — the anime-native path Torrentio
  supports (kitsu:ID:EPISODE, absolute numbering). This is what brings the
  big public/Russian trackers (Rutor etc.) into the anime flow that Nyaa and
  AnimeTosho don't carry. `{:ok, [source]}`; `{:ok, []}` when no kitsu id.
  """
  def torrentio_anime(nil, _episode), do: {:ok, []}
  def torrentio_anime(kitsu_id, episode), do: fetch_torrentio("series/kitsu:#{kitsu_id}:#{episode}")

  @doc "Torrentio anime movie by Kitsu id."
  def torrentio_anime_movie(nil), do: {:ok, []}
  def torrentio_anime_movie(kitsu_id), do: fetch_torrentio("movie/kitsu:#{kitsu_id}")

  defp fetch_torrentio(path) do
    url = "#{torrentio_base()}/stream/#{path}.json"
    req = Req.new(url: url, retry: :transient, max_retries: 1, receive_timeout: 20_000)

    case Req.get(req) do
      {:ok, %{status: 200, body: %{"streams" => streams}}} when is_list(streams) ->
        {:ok, streams |> Enum.map(&torrentio_source/1) |> Enum.reject(&is_nil/1)}

      {:ok, %{status: status}} ->
        {:error, {:torrentio, status}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  # With a debrid token, Torrentio's server pre-marks hashes it knows are
  # cached on the account's provider ("[RD+]" vs "[RD download]") — the same
  # signal Stremio users see. Those sources are near-guaranteed instant plays,
  # so they get ranked to the top.
  defp torrentio_base do
    case Application.get_env(:kala_app, :rd_token) do
      token when is_binary(token) and token != "" -> "#{@torrentio}/realdebrid=#{token}"
      _ -> @torrentio
    end
  end

  # A Torrentio stream's `title` is "<release name>\n👤 <seeders> 💾 <size> ⚙️ <tracker>".
  defp torrentio_source(%{"infoHash" => hash} = s) when is_binary(hash) and hash != "" do
    parse_torrentio(s, hash, false)
  end

  # Debrid-configured Torrentio omits infoHash; the hash is in the resolve URL.
  defp torrentio_source(%{"url" => url} = s) when is_binary(url) do
    case Regex.run(~r"/realdebrid/[^/]+/([0-9a-fA-F]{40})", url) do
      [_, hash] -> parse_torrentio(s, hash, String.starts_with?(s["name"] || "", "[RD+"))
      _ -> nil
    end
  end

  defp torrentio_source(_), do: nil

  defp parse_torrentio(s, hash, cached) do
    title = s["title"] || s["name"] || ""
    name = title |> String.split("\n") |> List.first() |> String.trim()

    provider =
      case Regex.run(~r/⚙️\s*([^\n]+)/u, title) do
        [_, p] -> "Torrentio/" <> String.trim(p)
        _ -> "Torrentio"
      end

    build_source(%{
      name: if(name == "", do: hash, else: name),
      provider: provider,
      hash: hash,
      seeders: torrentio_int(title, ~r/👤\s*(\d+)/u),
      size: torrentio_size(title)
    })
    |> Map.put(:cached, cached)
    |> Map.put(:langs, torrentio_langs(title))
  end

  # Torrentio's third title line carries audio languages as flag emoji
  # ("🇬🇧 / 🇮🇹") — parsed server-side from the actual file/track lists, so
  # it's more reliable than filename regexes. Flags are regional-indicator
  # pairs; map country → language code.
  @flag_langs %{
    "GB" => "en", "US" => "en", "IT" => "it", "ES" => "es", "MX" => "es",
    "FR" => "fr", "DE" => "de", "RU" => "ru", "JP" => "ja", "KR" => "ko",
    "CN" => "zh", "TW" => "zh", "BR" => "pt", "PT" => "pt", "PL" => "pl",
    "NL" => "nl", "SE" => "sv", "NO" => "no", "DK" => "da", "FI" => "fi",
    "GR" => "el", "TR" => "tr", "SA" => "ar", "AE" => "ar", "IL" => "he",
    "IN" => "hi", "TH" => "th", "VN" => "vi", "UA" => "uk", "RO" => "ro",
    "BG" => "bg", "RS" => "sr", "HR" => "hr", "CZ" => "cs", "SK" => "sk",
    "HU" => "hu", "ID" => "id", "MY" => "ms", "PH" => "tl", "LT" => "lt",
    "LV" => "lv", "EE" => "et"
  }

  defp torrentio_langs(title) do
    ~r/[\x{1F1E6}-\x{1F1FF}]{2}/u
    |> Regex.scan(title)
    |> Enum.map(fn [flag] ->
      country = flag |> String.to_charlist() |> Enum.map(&(&1 - 0x1F1E6 + ?A)) |> List.to_string()
      Map.get(@flag_langs, country, String.downcase(country))
    end)
    |> Enum.uniq()
  end

  defp torrentio_int(title, regex) do
    case Regex.run(regex, title) do
      [_, n] -> to_int(n)
      _ -> 0
    end
  end

  defp torrentio_size(title) do
    case Regex.run(~r/💾\s*([\d.]+)\s*(GB|MB|GiB|MiB|KB|KiB)/u, title) do
      [_, num, unit] ->
        {value, _} = Float.parse(num)
        trunc(value * unit_multiplier(unit))

      _ ->
        0
    end
  end

  # ── torznab (Jackett / Prowlarr; fronts many indexers) ────────────

  defp search_torznab(query) do
    url = "#{String.trim_trailing(jackett_url(), "/")}/api/v2.0/indexers/#{jackett_indexer()}/results/torznab/api"
    params = [apikey: jackett_key(), t: "search", q: query]

    case Req.get(Req.new(url: url, params: params, retry: false, receive_timeout: 25_000)) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, parse_torznab(body)}

      {:ok, %{status: status}} ->
        {:error, {:torznab, status}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  # Torznab is RSS with `<torznab:attr name=".." value=".."/>` extras. Parse it
  # the same regex way as Nyaa; the infohash comes from an attr or the magnet.
  defp parse_torznab(xml) do
    ~r/<item>(.*?)<\/item>/s
    |> Regex.scan(xml, capture: :all_but_first)
    |> Enum.map(fn [item] ->
      %{
        name: item |> field(~r{<title>(.*?)</title>}s) |> unescape(),
        provider: "Jackett",
        hash: torznab_hash(item),
        seeders: item |> torznab_attr("seeders") |> to_int(),
        size: torznab_size(item)
      }
    end)
    |> Enum.reject(&(&1.hash == ""))
    |> Enum.map(&build_source/1)
  end

  defp torznab_hash(item) do
    case torznab_attr(item, "infohash") do
      "" -> item |> torznab_attr("magneturl") |> extract_btih()
      hash -> normalize_infohash(hash)
    end
  end

  defp extract_btih(magnet) do
    case Regex.run(~r/urn:btih:([0-9A-Za-z]+)/, magnet) do
      [_, hash] -> normalize_infohash(hash)
      _ -> ""
    end
  end

  defp torznab_attr(item, name) do
    case Regex.run(~r/<torznab:attr\s+name="#{name}"\s+value="([^"]*)"/, item) do
      [_, value] -> value
      _ -> ""
    end
  end

  defp torznab_size(item) do
    case Regex.run(~r/<size>(\d+)<\/size>/, item) do
      [_, n] -> to_int(n)
      _ -> item |> torznab_attr("size") |> to_int()
    end
  end

  # Normalize an infohash to lowercase hex so hashes dedup across indexers
  # (some Torznab indexers emit base32 magnet hashes).
  defp normalize_infohash(hash) do
    hash = String.trim(hash)

    cond do
      Regex.match?(~r/^[0-9a-fA-F]{40}$/, hash) ->
        String.downcase(hash)

      Regex.match?(~r/^[A-Za-z2-7]{32}$/, hash) ->
        case Base.decode32(String.upcase(hash), padding: false) do
          {:ok, bin} -> Base.encode16(bin, case: :lower)
          :error -> String.downcase(hash)
        end

      true ->
        String.downcase(hash)
    end
  end

  defp field(text, regex) do
    case Regex.run(regex, text, capture: :all_but_first) do
      [value] -> String.trim(value)
      _ -> ""
    end
  end

  defp unescape(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace(["&#39;", "&apos;"], "'")
    |> String.replace(["&#34;", "&quot;"], "\"")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end

  defp parse_size(str) do
    case Regex.run(~r/([\d.]+)\s*(GiB|MiB|KiB|GB|MB|KB|B)/i, str) do
      [_, num, unit] ->
        {value, _} = Float.parse(num)
        trunc(value * unit_multiplier(unit))

      _ ->
        0
    end
  end

  defp unit_multiplier(unit) do
    case String.upcase(unit) do
      "GIB" -> 1_073_741_824
      "GB" -> 1_000_000_000
      "MIB" -> 1_048_576
      "MB" -> 1_000_000
      "KIB" -> 1_024
      "KB" -> 1_000
      _ -> 1
    end
  end

  # ── shared: build / rank / parse ──────────────────────────────────

  defp build_source(%{name: name, hash: hash, seeders: seeders, size: size} = attrs) do
    %{
      name: name,
      provider: attrs[:provider],
      hash: String.downcase(hash),
      magnet: magnet(hash, name),
      seeders: seeders,
      size: size,
      size_human: human_size(size),
      resolution: detect(name, resolution_patterns()),
      codec: detect(name, codec_patterns()),
      source: detect(name, source_patterns()),
      audio: detect(name, audio_patterns()),
      lang: detect_lang(name),
      cached: false
    }
  end

  @doc "Wrap a torrent already downloaded in the debrid account as a top-ranked source."
  def account_source(%{name: name, hash: hash, size: size}) do
    build_source(%{name: name, hash: hash, seeders: 0, size: size})
    |> Map.put(:cached, :library)
  end

  # Release-name language tags. `nil` means untagged, which in practice means
  # English on the indexers we query; "multi" covers dual-audio releases.
  @lang_detect [
    {"it", ~r/\b(ita|italian)\b/i},
    {"es", ~r/\b(spanish|espanol|castellano|latino|esp)\b/i},
    {"fr", ~r/\b(french|truefrench|vostfr|vff|vfq|vf)\b/i},
    {"de", ~r/\b(german|deutsch)\b/i},
    # MVO/AVO/DVO are Russian voice-over markers; LostFilm/NewStudio/HDRezka
    # are the big Russian dub groups (their releases often have no Cyrillic
    # in the filename).
    {"ru", ~r/\b(rus|russian|lostfilm|newstudio|hdrezka|mvo|avo|dvo)\b/i},
    {"hi", ~r/\b(hindi)\b/i},
    {"multi", ~r/\b(multi|dual)\b/i}
  ]
  @english ~r/\b(eng|english)\b/i

  defp detect_lang(name) do
    found = Enum.find_value(@lang_detect, fn {code, re} -> Regex.match?(re, name) && code end)

    cond do
      # Cyrillic-titled releases (Rutracker etc.) usually default to a Russian
      # dub even when the name mentions "Eng" tracks — treat as Russian.
      Regex.match?(~r/\p{Cyrillic}/u, name) -> "ru"
      found == nil -> nil
      found == "multi" -> "multi"
      Regex.match?(@english, name) -> "multi"
      true -> found
    end
  end

  @doc "True when the browser can decode this audio codec directly (no transcode needed)."
  def browser_audio?(%{audio: audio}), do: audio in [nil, "AAC", "Opus", "FLAC"]

  defp magnet(info_hash, name) do
    trackers = Enum.map_join(@trackers, &"&tr=#{URI.encode_www_form(&1)}")
    "magnet:?xt=urn:btih:#{info_hash}&dn=#{URI.encode_www_form(name)}#{trackers}"
  end

  # Seeders dominate; nudge toward 1080p, browser-friendly h264, and
  # audio Chrome can actually decode (DTS/TrueHD play silently in-browser).
  # Ordering, best-first (the way Stremio/Torrentio present sources):
  #   1. torrents already in the user's debrid account (instant, guaranteed)
  #   2. hashes Torrentio confirms as provider-cached (near-guaranteed)
  #   3. resolution tier (2160p > 1080p > 720p), bigger file breaking ties
  #      (size is the honest bitrate signal; seeders don't matter for playback
  #      once a debrid provider has the file)
  # Releases tagged with a language other than the preferred one (default
  # English; dual/multi audio is fine) sink below everything else.
  @doc """
  Pick one page of sources to probe, sampled across resolution tiers.

  Strictly taking the top of the ranking gives a wall of 2160p — someone
  who wants 1080p would have to probe (and rate-limit) through every 4K
  release before the first 1080p is even checked. Each page instead takes
  the best few from each tier (3× 2160p, 3× 1080p, 1× 720p), backfilling
  the remaining slots by overall rank. Returns `{page, rest}`; the page
  keeps the overall ranking order, so cached/library releases still lead.
  """
  @page_quotas [{"2160p", 3}, {"1080p", 3}, {"720p", 1}]

  def probe_page(sources, size) do
    by_tier = Enum.group_by(sources, & &1.resolution)

    quota =
      @page_quotas
      |> Enum.flat_map(fn {tier, n} -> by_tier |> Map.get(tier, []) |> Enum.take(n) end)
      |> MapSet.new(& &1.hash)

    backfill =
      sources
      |> Enum.reject(&MapSet.member?(quota, &1.hash))
      |> Enum.take(max(size - MapSet.size(quota), 0))
      |> MapSet.new(& &1.hash)

    chosen = MapSet.union(quota, backfill)
    {page, rest} = Enum.split_with(sources, &MapSet.member?(chosen, &1.hash))
    {page, rest}
  end

  @doc false
  def rank(sources), do: Enum.sort_by(sources, &score/1, :desc)

  @doc false
  def rank_playable(pairs), do: Enum.sort_by(pairs, fn {source, _stream} -> score(source) end, :desc)

  defp score(source) do
    tier =
      case source.resolution do
        "2160p" -> 3
        "1080p" -> 2
        "720p" -> 1
        _ -> 0
      end

    cached_boost =
      case Map.get(source, :cached) do
        :library -> 2_000_000_000_000_000
        true -> 1_000_000_000_000_000
        _ -> 0
      end

    # A cam is never the pick when a proper release exists at the same
    # resolution: half-tier penalty sinks cams below every proper release
    # in their tier (still above the tier below — a 4K cam beats nothing
    # into 1080p territory it doesn't deserve, and cams stay selectable).
    cam_penalty = if source.source == "CAM", do: -600_000_000_000_000, else: 0

    # ~1PB per tier step keeps tiers dominant over any real file size.
    cached_boost + lang_score(source) + cam_penalty +
      tier * 1_000_000_000_000_000 + (source.size || 0)
  end

  # Wrong-language releases sink far below everything. With a non-English
  # preference (KALA_LANG=ru etc.), releases explicitly tagged with that
  # language get a half-tier boost — dubs float above untagged (≈ English)
  # releases inside each resolution tier — and multi/dual gets half that.
  # An English preference keeps the neutral behavior: untagged already is
  # English in practice, so there's nothing to boost over.
  # Boosts are whole-tier-sized (>= @tier so they can outrank resolution) —
  # when the user sets a non-English language, releases in that language (or
  # dual/multi, which contain it) should sort ABOVE a higher-res release that
  # doesn't have it. A dedicated single-language match beats multi; a release
  # in a *different* named language sinks far below everything.
  @tier 1_000_000_000_000_000
  @lang_exact 8 * @tier
  @lang_multi 6 * @tier
  @lang_wrong -10_000_000_000_000_000

  defp lang_score(source) do
    preferred = Kala.Config.lang()
    langs = Map.get(source, :langs) || []

    cond do
      preferred == "en" ->
        # English default: untagged (≈English) and multi are neutral, only a
        # wrong named language sinks — no boosting to reorder resolution.
        cond do
          langs != [] and "en" in langs -> 0
          langs != [] -> @lang_wrong
          Map.get(source, :lang) in [nil, "multi", "en"] -> 0
          true -> @lang_wrong
        end

      # Torrentio's parsed language list is authoritative when present.
      langs != [] ->
        cond do
          preferred in langs and length(langs) == 1 -> @lang_exact
          preferred in langs -> @lang_multi
          true -> @lang_wrong
        end

      true ->
        case Map.get(source, :lang) do
          ^preferred -> @lang_exact
          "multi" -> @lang_multi
          nil -> 0
          _ -> @lang_wrong
        end
    end
  end

  defp detect(name, patterns) do
    Enum.find_value(patterns, fn {label, regex} ->
      if Regex.match?(regex, name), do: label
    end)
  end

  defp resolution_patterns do
    [{"2160p", ~r/2160p|4k/i}, {"1080p", ~r/1080p/i}, {"720p", ~r/720p/i}, {"480p", ~r/480p/i}]
  end

  defp codec_patterns do
    [{"h265", ~r/x265|h\.?265|hevc/i}, {"av1", ~r/\bav1\b/i}, {"h264", ~r/x264|h\.?264|avc/i}]
  end

  defp audio_patterns do
    [
      {"TrueHD", ~r/true-?hd/i},
      {"DTS", ~r/\bdts\b|dts-?hd|dts-?x/i},
      {"Atmos", ~r/atmos/i},
      {"FLAC", ~r/\bflac\b/i},
      {"DDP", ~r/\bddp|dd\+|e-?ac-?3/i},
      {"AC3", ~r/\bac-?3\b|\bdd5\.1\b|\bdd\b/i},
      {"AAC", ~r/\baac/i},
      {"Opus", ~r/\bopus/i}
    ]
  end

  defp source_patterns do
    [
      {"BluRay", ~r/blu-?ray|bdrip|brrip|bd\b/i},
      {"WEB", ~r/web-?dl|webrip|\bweb\b/i},
      {"HDTV", ~r/hdtv/i},
      {"CAM", ~r/\bcam\b|camrip|hd-?cam|telesync|hd-?ts|\bts\b|telecine|hq-?cam/i}
    ]
  end

  defp human_size(bytes) when bytes >= 1_073_741_824, do: "#{Float.round(bytes / 1_073_741_824, 2)} GB"
  defp human_size(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp human_size(bytes), do: "#{bytes} B"

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp to_int(_), do: 0

  defp jackett_url, do: Application.get_env(:kala_app, :jackett_url)
  defp jackett_key, do: Application.get_env(:kala_app, :jackett_api_key)
  defp jackett_indexer, do: Application.get_env(:kala_app, :jackett_indexer) || "all"
end
