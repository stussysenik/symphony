defmodule SymphonyElixirWeb.IssueDetailLive do
  @moduledoc """
  Per-issue detail view showing event timeline, git diff, tokens, and error state.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  import Phoenix.HTML, only: [raw: 1]

  alias SymphonyElixir.{Config, EventLog}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000

  @impl true
  def mount(%{"identifier" => identifier}, _session, socket) do
    socket =
      socket
      |> assign(:identifier, identifier)
      |> assign(:payload, load_issue_payload(identifier))
      |> assign(:events, EventLog.issue_events(identifier))
      |> assign(:now, DateTime.utc_now())
      |> assign(:diff_stat, nil)
      |> assign(:diff_full, nil)
      |> assign(:diff_commits, nil)
      |> assign(:show_full_diff, false)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
      send(self(), :load_diff)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    identifier = socket.assigns.identifier

    {:noreply,
     socket
     |> assign(:payload, load_issue_payload(identifier))
     |> assign(:events, EventLog.issue_events(identifier))
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:load_diff, socket) do
    identifier = socket.assigns.identifier
    workspace_path = resolve_workspace_path(identifier, socket.assigns.payload)

    {stat, full, commits} = load_git_diff(workspace_path)

    {:noreply,
     socket
     |> assign(:diff_stat, stat)
     |> assign(:diff_full, full)
     |> assign(:diff_commits, commits)}
  end

  @impl true
  def handle_event("toggle_diff", _params, socket) do
    {:noreply, assign(socket, :show_full_diff, !socket.assigns.show_full_diff)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <div class="detail-back">
        <a href="/">&larr; Back to dashboard</a>
      </div>

      <header class="detail-header">
        <div class="detail-header-top">
          <h1 class="detail-title"><%= @identifier %></h1>
          <%= if @payload do %>
            <span class={state_badge_class(@payload.status)}>
              <%= @payload.status %>
            </span>
          <% end %>
        </div>

        <%= if @payload do %>
          <div class="detail-meta">
            <span class="detail-meta-item">
              Runtime: <strong><%= format_runtime(@payload, @now) %></strong>
            </span>
            <span class="detail-meta-item">
              Tokens: <strong><%= format_tokens(@payload) %></strong>
            </span>
            <%= if @payload.running && @payload.running.turn_count > 0 do %>
              <span class="detail-meta-item">
                Turns: <strong><%= @payload.running.turn_count %></strong>
              </span>
            <% end %>
          </div>

          <div class="quick-links">
            <a href={"https://linear.app/issue/#{@identifier}"} target="_blank" class="quick-link">
              Linear
            </a>
            <a href={"https://github.com/stussysenik/mymind-clone-web/tree/feature/#{@identifier}"} target="_blank" class="quick-link">
              GitHub Branch
            </a>
            <%= if @payload.workspace do %>
              <span class="quick-link quick-link-mono" title={@payload.workspace.path}>
                <%= truncate_path(@payload.workspace.path) %>
              </span>
            <% end %>
          </div>
        <% end %>
      </header>

      <%= if @payload == nil do %>
        <section class="section-card">
          <p class="empty-state">Issue not found in current orchestrator state.</p>
        </section>
      <% else %>
        <%!-- Error state --%>
        <%= if @payload.last_error do %>
          <section class="error-card detail-error-card">
            <h2 class="error-title">Error</h2>
            <p class="error-copy"><%= @payload.last_error %></p>
            <%= if @payload.retry do %>
              <div class="error-meta">
                <span>Attempt: <strong><%= @payload.attempts.current_retry_attempt %></strong></span>
                <span>Due at: <strong class="mono"><%= @payload.retry.due_at || "n/a" %></strong></span>
              </div>
            <% end %>
          </section>
        <% end %>

        <%!-- Event timeline --%>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Event Timeline</h2>
              <p class="section-copy">Chronological agent events, newest first. Auto-updates via PubSub.</p>
            </div>
          </div>

          <%= if @events == [] do %>
            <p class="empty-state">No events recorded yet.</p>
          <% else %>
            <div class="timeline">
              <div :for={event <- @events} class="timeline-row">
                <span class="timeline-time mono"><%= format_event_time(event.timestamp) %></span>
                <span class={event_type_badge_class(event.event)}>
                  <%= event.event %>
                </span>
                <span class="timeline-message"><%= event.message || "—" %></span>
                <%= if token_delta = Map.get(event, :token_delta) do %>
                  <span class="timeline-tokens mono" title={"Token delta: in=#{Map.get(token_delta, :input, 0)} out=#{Map.get(token_delta, :output, 0)}"}>
                    +<%= Map.get(token_delta, :total, 0) %>t
                  </span>
                <% end %>
              </div>
            </div>
          <% end %>
        </section>

        <%!-- Code changes --%>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Code Changes</h2>
              <p class="section-copy">Git diff against origin/main in the agent workspace.</p>
            </div>
            <%= if @diff_full do %>
              <button type="button" class="diff-toggle subtle-button" phx-click="toggle_diff">
                <%= if @show_full_diff, do: "Show Summary", else: "Show Full Diff" %>
              </button>
            <% end %>
          </div>

          <%= if @diff_stat do %>
            <pre class="code-panel"><%= @diff_stat %></pre>
          <% else %>
            <p class="empty-state">No diff data available (workspace may not exist yet).</p>
          <% end %>

          <%= if @show_full_diff && @diff_full do %>
            <pre class="code-panel code-panel-diff"><%= raw(colorize_diff(@diff_full)) %></pre>
          <% end %>

          <%= if @diff_commits do %>
            <div class="commits-section">
              <h3 class="commits-title">Branch Commits</h3>
              <pre class="code-panel"><%= @diff_commits %></pre>
            </div>
          <% end %>
        </section>

        <%!-- Session info --%>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Session Info</h2>
            </div>
          </div>

          <div class="session-info-grid">
            <div class="session-info-item">
              <span class="session-info-label">Session ID</span>
              <span class="session-info-value mono"><%= session_id(@payload) %></span>
            </div>
            <div class="session-info-item">
              <span class="session-info-label">Workspace</span>
              <span class="session-info-value mono"><%= workspace_display(@payload) %></span>
            </div>
            <div class="session-info-item">
              <span class="session-info-label">Worker Host</span>
              <span class="session-info-value"><%= worker_host(@payload) %></span>
            </div>
            <div class="session-info-item">
              <span class="session-info-label">Status</span>
              <span class="session-info-value"><%= @payload.status %></span>
            </div>
          </div>
        </section>
      <% end %>
    </section>
    """
  end

  # -- Data loading --

  defp load_issue_payload(identifier) do
    case Presenter.issue_payload(identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} -> payload
      {:error, _} -> nil
    end
  end

  defp resolve_workspace_path(identifier, payload) do
    cond do
      payload && payload.workspace && payload.workspace.path ->
        payload.workspace.path

      true ->
        Path.join(Config.settings!().workspace.root, identifier)
    end
  end

  defp load_git_diff(workspace_path) do
    if File.dir?(workspace_path) do
      stat = run_git(workspace_path, ["diff", "origin/main", "--stat"])
      full = run_git(workspace_path, ["diff", "origin/main"])
      commits = run_git(workspace_path, ["log", "--oneline", "-20", "origin/main..HEAD"])
      {stat, full, commits}
    else
      {nil, nil, nil}
    end
  end

  defp run_git(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> if String.trim(output) == "", do: nil, else: output
      _ -> nil
    end
  end

  # -- Helpers --

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp format_runtime(payload, now) do
    case payload do
      %{running: %{started_at: started_at}} when not is_nil(started_at) ->
        seconds = runtime_seconds_from_started_at(started_at, now)
        format_runtime_seconds(seconds)

      _ ->
        "n/a"
    end
  end

  defp format_tokens(payload) do
    case payload do
      %{running: %{tokens: %{total_tokens: total}}} when is_integer(total) ->
        format_int(total)

      _ ->
        "n/a"
    end
  end

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> max(0, DateTime.diff(now, parsed, :second))
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp format_event_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_event_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> ts
    end
  end

  defp format_event_time(_), do: "—"

  defp event_type_badge_class(event) do
    event_str = to_string(event) |> String.downcase()

    cond do
      String.contains?(event_str, ["error", "fail", "crash"]) -> "event-type-badge event-type-badge-error"
      String.contains?(event_str, ["complet", "success", "done", "finish"]) -> "event-type-badge event-type-badge-success"
      true -> "event-type-badge event-type-badge-info"
    end
  end

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["running", "active", "progress"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["error", "fail", "blocked"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["retry", "pending", "todo", "queued"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp colorize_diff(diff) when is_binary(diff) do
    diff
    |> String.split("\n")
    |> Enum.map(fn line ->
      escaped = Phoenix.HTML.html_escape(line) |> Phoenix.HTML.safe_to_string()

      cond do
        String.starts_with?(line, "+") && !String.starts_with?(line, "+++") ->
          ~s(<span class="diff-add">#{escaped}</span>)

        String.starts_with?(line, "-") && !String.starts_with?(line, "---") ->
          ~s(<span class="diff-del">#{escaped}</span>)

        String.starts_with?(line, "@@") ->
          ~s(<span class="diff-hunk">#{escaped}</span>)

        true ->
          escaped
      end
    end)
    |> Enum.join("\n")
  end

  defp colorize_diff(_), do: ""

  defp truncate_path(nil), do: "n/a"

  defp truncate_path(path) when is_binary(path) do
    if String.length(path) > 50 do
      "..." <> String.slice(path, -47, 47)
    else
      path
    end
  end

  defp session_id(%{running: %{session_id: id}}) when is_binary(id), do: id
  defp session_id(_), do: "n/a"

  defp workspace_display(%{workspace: %{path: path}}) when is_binary(path), do: path
  defp workspace_display(_), do: "n/a"

  defp worker_host(%{workspace: %{host: host}}) when is_binary(host), do: host
  defp worker_host(_), do: "local"
end
