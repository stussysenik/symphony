defmodule SymphonyElixir.AssetCache do
  @moduledoc """
  Downloads and caches visual assets to the agent's workspace.

  After `AssetCollector` gathers asset metadata, AssetCache downloads remote
  assets (e.g., Linear attachments) to the local filesystem so they can be
  passed to the Codex agent as file paths.

  ## Cache structure

  Assets are stored in `<workspace>/assets/` with a manifest:

      workspace/
      └── assets/
          ├── manifest.json     ← Metadata for all cached assets
          ├── linear_abc123.png ← Downloaded from Linear attachment
          ├── linear_def456.jpg ← Downloaded from Linear attachment
          └── (project assets are referenced in-place, not copied)

  ## Manifest format

      {
        "assets": [
          {
            "source": "linear",
            "title": "Homepage Mockup",
            "url": "https://...",
            "local_path": "/path/to/workspace/assets/linear_abc123.png",
            "id": "abc123"
          }
        ],
        "cached_at": "2024-01-15T10:00:00Z"
      }

  ## Usage

      {:ok, cached_assets} = AssetCache.cache_assets(collected_assets, workspace_path)
      # Each asset now has a :local_path field pointing to the cached file
  """

  require Logger

  @doc """
  Downloads and caches remote assets, returning the list with local_path fields added.

  Local assets (source: :project) already have paths and are passed through unchanged.
  Remote assets (source: :linear) are downloaded to workspace/assets/.
  Failed downloads are logged and excluded from the result.
  """
  @spec cache_assets([map()], String.t()) :: {:ok, [map()]}
  def cache_assets(assets, workspace) do
    cache_dir = Path.join(workspace, "assets")
    File.mkdir_p!(cache_dir)

    cached =
      assets
      |> Enum.map(&cache_asset(&1, cache_dir))
      |> Enum.reject(&is_nil/1)

    write_manifest(cached, cache_dir)
    Logger.info("AssetCache: cached #{length(cached)}/#{length(assets)} asset(s)")
    {:ok, cached}
  end

  # Cache a single asset — route by source type
  defp cache_asset(%{source: :linear, url: url} = asset, cache_dir) do
    case download_asset(url, cache_dir, asset) do
      {:ok, local_path} ->
        Map.put(asset, :local_path, local_path)

      {:error, reason} ->
        Logger.warning("AssetCache: failed to download #{url}: #{inspect(reason)}")
        nil
    end
  end

  # Project assets already have local paths — no download needed
  defp cache_asset(%{source: :project, path: path} = asset, _cache_dir) do
    if File.exists?(path) do
      Map.put(asset, :local_path, path)
    else
      Logger.warning("AssetCache: project asset missing: #{path}")
      nil
    end
  end

  defp cache_asset(asset, _cache_dir) do
    Logger.warning("AssetCache: unknown asset source: #{inspect(asset)}")
    nil
  end

  # Download a remote URL to the cache directory
  defp download_asset(url, cache_dir, asset) when is_binary(url) do
    filename = generate_filename(asset)
    local_path = Path.join(cache_dir, filename)

    # Skip if already cached
    if File.exists?(local_path) do
      {:ok, local_path}
    else
      case Req.get(url, connect_options: [timeout: 30_000], receive_timeout: 60_000) do
        {:ok, %{status: 200, body: body}} when is_binary(body) ->
          File.write!(local_path, body)
          {:ok, local_path}

        {:ok, %{status: status}} ->
          {:error, {:http_status, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Generate a deterministic filename from the asset metadata
  defp generate_filename(%{source: source, id: id}) when is_binary(id) do
    ext = ".png" # Default extension; could be derived from URL
    "#{source}_#{sanitize_filename(id)}#{ext}"
  end

  defp generate_filename(%{source: source, url: url}) when is_binary(url) do
    # Use the URL's filename or a hash of the URL
    basename = url |> URI.parse() |> Map.get(:path, "") |> Path.basename()

    if basename != "" && String.contains?(basename, ".") do
      "#{source}_#{sanitize_filename(basename)}"
    else
      hash = :crypto.hash(:md5, url) |> Base.encode16(case: :lower) |> binary_part(0, 12)
      "#{source}_#{hash}.png"
    end
  end

  defp generate_filename(%{source: source, title: title}) when is_binary(title) do
    "#{source}_#{sanitize_filename(title)}"
  end

  defp generate_filename(_asset) do
    hash = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "asset_#{hash}.png"
  end

  # Remove characters that aren't safe for filenames
  defp sanitize_filename(name) do
    name
    |> String.replace(~r/[^\w\-.]/, "_")
    |> String.slice(0, 100)
  end

  # Write a JSON manifest of all cached assets
  defp write_manifest(assets, cache_dir) do
    manifest = %{
      "assets" => Enum.map(assets, &serialize_asset/1),
      "cached_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    manifest_path = Path.join(cache_dir, "manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
  end

  # Convert asset map to JSON-safe format (atoms to strings)
  defp serialize_asset(asset) do
    asset
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Map.new()
  end
end
