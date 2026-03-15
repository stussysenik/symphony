defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{AssetCache, AssetCollector, Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    worker_hosts =
      candidate_worker_hosts(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_hosts=#{inspect(worker_hosts_for_log(worker_hosts))}")

    case run_on_worker_hosts(issue, codex_update_recipient, opts, worker_hosts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_hosts(issue, codex_update_recipient, opts, [worker_host | rest]) do
    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} when rest != [] ->
        Logger.warning("Agent run failed for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}; trying next worker host")
        run_on_worker_hosts(issue, codex_update_recipient, opts, rest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_on_worker_hosts(_issue, _codex_update_recipient, _opts, []), do: {:error, :no_worker_hosts_available}

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    # Collect and cache visual assets on the first turn
    cached_assets = collect_visual_assets(issue, workspace, turn_number)
    prompt = build_turn_prompt(issue, Keyword.put(opts, :assets, cached_assets), turn_number, max_turns)

    log_ingestion_summary(issue, prompt, cached_assets, workspace, turn_number, max_turns)
    turn_started_at = System.monotonic_time(:millisecond)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue),
             assets: cached_assets
           ) do
      log_turn_completion(issue, turn_session, workspace, turn_number, max_turns, turn_started_at)
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp candidate_worker_hosts(nil, []), do: [nil]

  defp candidate_worker_hosts(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" ->
        [host | Enum.reject(hosts, &(&1 == host))]

      _ when hosts == [] ->
        [nil]

      _ ->
        hosts
    end
  end

  defp worker_hosts_for_log(worker_hosts) do
    Enum.map(worker_hosts, &worker_host_for_log/1)
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  # Log a summary of what the agent is about to ingest before each turn.
  defp log_ingestion_summary(issue, prompt, assets, workspace, turn_number, max_turns) do
    prompt_preview = String.slice(prompt, 0, 2000)
    prompt_hash = :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower) |> String.slice(0, 12)
    prompt_len = String.length(prompt)

    asset_manifest =
      assets
      |> Enum.map(fn asset ->
        name = Map.get(asset, :filename) || Map.get(asset, "filename") || "unknown"
        size = Map.get(asset, :size) || Map.get(asset, "size") || "?"
        type = Map.get(asset, :content_type) || Map.get(asset, "content_type") || "?"
        "#{name} (#{size} bytes, #{type})"
      end)
      |> Enum.join(", ")

    workspace_status = workspace_git_status(workspace)

    Logger.info("""
    [ingestion_summary] #{issue_context(issue)} turn=#{turn_number}/#{max_turns}
      prompt_length=#{prompt_len} prompt_hash=#{prompt_hash}
      prompt_preview=#{prompt_preview}
      visual_assets=#{length(assets)} [#{asset_manifest}]
      workspace_status=#{workspace_status}
    """)
  end

  # Log a summary after each turn completes.
  defp log_turn_completion(issue, turn_session, workspace, turn_number, max_turns, turn_started_at) do
    duration_ms = System.monotonic_time(:millisecond) - turn_started_at
    session_id = turn_session[:session_id] || "n/a"
    modified_files = workspace_modified_files(workspace)

    Logger.info("""
    [turn_summary] #{issue_context(issue)} turn=#{turn_number}/#{max_turns}
      session_id=#{session_id} duration_ms=#{duration_ms}
      modified_files=#{modified_files}
    """)
  end

  defp workspace_git_status(workspace) when is_binary(workspace) do
    case System.cmd("git", ["status", "--short"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        output |> String.trim() |> String.replace("\n", "; ")

      {_, _} ->
        "unavailable"
    end
  rescue
    _ -> "unavailable"
  end

  defp workspace_git_status(_workspace), do: "unavailable"

  defp workspace_modified_files(workspace) when is_binary(workspace) do
    case System.cmd("git", ["diff", "--name-only", "HEAD"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        files = output |> String.trim()
        if files == "", do: "(none)", else: String.replace(files, "\n", ", ")

      {_, _} ->
        "unavailable"
    end
  rescue
    _ -> "unavailable"
  end

  defp workspace_modified_files(_workspace), do: "unavailable"

  # Collect and cache visual assets on the first turn only.
  # Subsequent turns reuse the cached assets already in the workspace.
  defp collect_visual_assets(issue, workspace, 1) do
    with {:ok, collected} <- AssetCollector.collect_assets(issue, workspace),
         {:ok, cached} <- AssetCache.cache_assets(collected, workspace) do
      cached
    else
      {:error, reason} ->
        Logger.warning("Failed to collect visual assets for #{issue_context(issue)}: #{inspect(reason)}")
        []
    end
  end

  defp collect_visual_assets(_issue, _workspace, _turn_number), do: []
end
