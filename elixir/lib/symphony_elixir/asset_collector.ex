defmodule SymphonyElixir.AssetCollector do
  @moduledoc """
  Gathers visual assets from multiple sources for an issue.

  Symphony agents work best when they can SEE what they're building. This module
  collects visual assets from three sources:

  1. **Linear attachments** — Images attached directly to the Linear issue
     (mockups, screenshots, design exports)
  2. **Project assets** — Design files found in the workspace's conventional
     directories (design/, assets/, mockups/, screenshots/)
  3. **Website screenshots** — Future: automated captures of the running app

  ## Architecture

  AssetCollector is a pure data-gathering step. It returns a list of asset
  metadata (URLs, paths, titles) but does NOT download anything. Downloading
  and caching is handled by `AssetCache`, keeping collection fast and
  side-effect-free.

  ## Usage

      {:ok, assets} = AssetCollector.collect_assets(issue, workspace_path)
      # assets is a flat list of %{source: atom, url: string, title: string, ...}
  """

  require Logger

  @image_extensions ~w(.png .jpg .jpeg .gif .webp .svg)
  @figma_pattern ~r/figma\.com/
  @asset_directories ~w(design assets mockups screenshots)

  @doc """
  Collects visual assets from all available sources for the given issue.

  Returns `{:ok, assets}` where assets is a flat list of asset maps, each
  containing `:source`, `:url` or `:path`, `:title`, and optional `:id`.
  """
  @spec collect_assets(struct(), String.t()) :: {:ok, [map()]}
  def collect_assets(issue, workspace) do
    assets =
      []
      |> then(&(collect_linear_attachments(issue) ++ &1))
      |> then(&(discover_project_assets(workspace) ++ &1))

    Logger.info("AssetCollector: found #{length(assets)} visual asset(s) for #{issue.identifier}")
    {:ok, assets}
  end

  @doc """
  Collects only Linear attachments from the issue.
  Useful when you want just the issue-specific assets without project scanning.
  """
  @spec collect_linear_attachments(struct()) :: [map()]
  def collect_linear_attachments(issue) do
    (issue.attachments || [])
    |> Enum.filter(&image_attachment?/1)
    |> Enum.map(fn attachment ->
      %{
        source: :linear,
        url: attachment.url,
        title: attachment.title || "Untitled",
        id: attachment.id
      }
    end)
  end

  @doc """
  Scans the workspace for conventional design asset directories.
  Looks in: design/, assets/, mockups/, screenshots/
  """
  @spec discover_project_assets(String.t()) :: [map()]
  def discover_project_assets(workspace) do
    @asset_directories
    |> Enum.flat_map(&scan_directory(workspace, &1))
  end

  # -- Private helpers --

  # Check if a Linear attachment is an image (by URL extension or Figma link)
  defp image_attachment?(%{url: url}) when is_binary(url) do
    lower_url = String.downcase(url)

    Enum.any?(@image_extensions, &String.contains?(lower_url, &1)) ||
      Regex.match?(@figma_pattern, lower_url)
  end

  defp image_attachment?(_), do: false

  # Scan a single directory within the workspace for image files
  defp scan_directory(workspace, dir_name) do
    dir_path = Path.join(workspace, dir_name)

    if File.dir?(dir_path) do
      dir_path
      |> File.ls!()
      |> Enum.filter(&image_file?/1)
      |> Enum.map(fn filename ->
        %{
          source: :project,
          path: Path.join(dir_path, filename),
          title: filename,
          directory: dir_name
        }
      end)
    else
      []
    end
  rescue
    _ -> []
  end

  # Check if a filename has an image extension
  defp image_file?(filename) do
    ext = Path.extname(filename) |> String.downcase()
    ext in @image_extensions
  end
end
