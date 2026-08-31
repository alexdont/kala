defmodule KinoTheatre.Dictionary do
  @moduledoc """
  Word lookups for the built-in hover dictionary. Japanese comes from Jisho
  (JMdict-backed, same data Yomitan users rely on); results are cached in ETS
  so repeated hovers are instant and we're gentle on Jisho.

  French comes from Wiktionary's REST definition endpoint (no key), which gives a
  French word's definitions in English — ideal for the user (and his father)
  studying French with an English UI.
  """

  @table :dict_cache
  @jisho "https://jisho.org/api/v1/search/words"
  @wiktionary "https://en.wiktionary.org/api/rest_v1/page/definition"
  @user_agent "DebridTheatre/1.0 (personal language-learning app)"

  def init do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:public, :named_table, :set, read_concurrency: true])
      _ref -> @table
    end
  end

  def lookup("ja", term), do: cached({:ja, term}, fn -> fetch_jisho(term) end)
  def lookup("fr", term), do: cached({:fr, normalize_fr(term)}, fn -> fetch_french(term) end)
  def lookup(_lang, _term), do: {:error, :unsupported_language}

  defp cached(key, fetch) do
    case :ets.lookup(@table, key) do
      [{^key, entries}] ->
        {:ok, entries}

      [] ->
        with {:ok, entries} <- fetch.() do
          :ets.insert(@table, {key, entries})
          {:ok, entries}
        end
    end
  end

  defp fetch_jisho(term) do
    req = Req.new(url: @jisho, params: [keyword: term], receive_timeout: 10_000, retry: :transient, max_retries: 2)

    case Req.get(req) do
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, data |> Enum.take(4) |> Enum.map(&simplify/1)}
      {:ok, %{status: status}} -> {:error, {:jisho, status}}
      {:error, exception} -> {:error, exception}
    end
  end

  defp fetch_french(term) do
    word = normalize_fr(term)

    if word == "" do
      {:ok, []}
    else
      req =
        Req.new(
          url: "#{@wiktionary}/#{URI.encode(word)}",
          headers: [{"user-agent", @user_agent}],
          receive_timeout: 10_000,
          retry: :transient,
          max_retries: 2
        )

      case Req.get(req) do
        {:ok, %{status: 200, body: %{"fr" => sections}}} when is_list(sections) and sections != [] ->
          {:ok, [%{"word" => word, "reading" => nil, "jlpt" => nil, "senses" => fr_senses(sections)}]}

        # 200 without a French section, or no page at all: cache an empty result.
        {:ok, %{status: s}} when s in [200, 404] ->
          {:ok, []}

        {:ok, %{status: status}} ->
          {:error, {:wiktionary, status}}

        {:error, exception} ->
          {:error, exception}
      end
    end
  end

  # French words arrive as they appear on screen: lowercase, drop a leading
  # elision (l'/d'/j'/qu'…), and trim surrounding punctuation, so "L'homme," and
  # "Qu'est-ce" resolve to real headwords.
  defp normalize_fr(term) do
    term
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/^(l|d|j|n|m|t|s|c|qu)['’]/u, "")
    |> String.replace(~r/^[^\p{L}]+|[^\p{L}]+$/u, "")
  end

  # One tooltip sense per Wiktionary part-of-speech section (Verb, Noun, …), with
  # its English glosses (HTML stripped).
  defp fr_senses(sections) do
    Enum.map(sections, fn s ->
      %{
        "pos" => if(s["partOfSpeech"] in [nil, ""], do: [], else: [s["partOfSpeech"]]),
        "definitions" =>
          (s["definitions"] || [])
          |> Enum.map(fn d -> strip_html(d["definition"] || "") end)
          |> Enum.reject(&(&1 == ""))
          |> Enum.take(4)
      }
    end)
  end

  defp strip_html(html) do
    html
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Reduce Jisho's verbose entry to what the tooltip shows.
  defp simplify(entry) do
    jp = List.first(entry["japanese"] || []) || %{}

    %{
      "word" => jp["word"] || jp["reading"],
      "reading" => jp["reading"],
      "jlpt" => List.first(entry["jlpt"] || []),
      "senses" =>
        Enum.map(entry["senses"] || [], fn s ->
          %{"definitions" => s["english_definitions"] || [], "pos" => s["parts_of_speech"] || []}
        end)
    }
  end
end
