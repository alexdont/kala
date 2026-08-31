defmodule KinoTheatre.Tmdb do
  @moduledoc """
  Minimal TMDB v3 API client — search, movie/TV details, season episodes.

  Accepts either a v3 API key or a v4 read-access token (JWTs start with "eyJ").
  """

  @base "https://api.themoviedb.org/3"
  @image_base "https://image.tmdb.org/t/p"

  def configured?, do: key() not in [nil, ""]

  @doc """
  Search movies and TV shows. Returns `{:ok, results, more?}` where `more?`
  says whether further pages exist.
  """
  def search(query, page \\ 1) do
    with {:ok, %{"results" => results} = body} <- get("/search/multi", query: query, page: page) do
      {:ok,
       results
       |> Enum.filter(&(&1["media_type"] in ~w(movie tv)))
       |> Enum.map(&normalize/1), page < (body["total_pages"] || 1)}
    end
  end

  @doc """
  Trending movies or TV shows this week — `type` is `"movie"` or `"tv"`.
  Returns `{:ok, results, more?}` like `search/2`.
  """
  def trending(type, page \\ 1) when type in ~w(movie tv) do
    with {:ok, %{"results" => results} = body} <- get("/trending/#{type}/week", page: page) do
      {:ok, Enum.map(results, &normalize(Map.put(&1, "media_type", type))),
       page < (body["total_pages"] || 1)}
    end
  end

  # Append external_ids so `imdb_id/1` works for both movies (top-level imdb_id)
  # and TV (external_ids.imdb_id) — used to query Torrentio for more sources.
  def movie(id), do: get("/movie/#{id}", append_to_response: "external_ids")
  def tv(id), do: get("/tv/#{id}", append_to_response: "external_ids")
  def season(tv_id, season_number), do: get("/tv/#{tv_id}/season/#{season_number}")

  @doc "The IMDb id (tt…) for a details map, or nil."
  def imdb_id(details) when is_map(details), do: details["imdb_id"] || get_in(details, ["external_ids", "imdb_id"])
  def imdb_id(_), do: nil

  def poster_url(nil, _size), do: nil
  def poster_url(path, size), do: "#{@image_base}/#{size}#{path}"

  defp normalize(%{"media_type" => type} = r) do
    %{
      id: r["id"],
      type: type,
      title: r["title"] || r["name"],
      year: year(r["release_date"] || r["first_air_date"]),
      overview: r["overview"],
      poster: poster_url(r["poster_path"], "w342"),
      vote: r["vote_average"],
      popularity: r["popularity"]
    }
  end

  def year(nil), do: nil
  def year(""), do: nil
  def year(<<year::binary-size(4), _rest::binary>>), do: year

  defp get(path, params \\ []) do
    key = key()

    {auth, params} =
      if String.starts_with?(key, "eyJ") do
        {[auth: {:bearer, key}], params}
      else
        {[], Keyword.put(params, :api_key, key)}
      end

    opts = [url: path, params: params] ++ auth

    case Req.get(Req.new(base_url: @base, retry: false), opts) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:tmdb, status, body["status_message"] || body}}
      {:error, exception} -> {:error, exception}
    end
  end

  defp key, do: Application.get_env(:kino_app, :tmdb_key)
end
