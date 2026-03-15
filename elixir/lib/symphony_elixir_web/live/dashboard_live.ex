defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.EventLog
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:events, EventLog.recent_events(25))
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
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
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:events, EventLog.recent_events(25))
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("toggle_theme", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
            <button
              type="button"
              class="theme-toggle subtle-button"
              onclick="(function(){var r=document.documentElement,t=r.getAttribute('data-theme')==='dark'?'light':'dark';r.setAttribute('data-theme',t);localStorage.setItem('symphony-theme',t);})()"
            >
              Theme
            </button>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <%= if is_map(@payload.rate_limits) and rate_limit_structured?(@payload.rate_limits) do %>
            <div class="rate-limit-grid">
              <div class="rate-limit-card">
                <p class="rate-limit-label">Limit</p>
                <p class="rate-limit-value"><%= rate_limit_id(@payload.rate_limits) %></p>
              </div>
              <%= if rate_limit_bucket(@payload.rate_limits, "primary") do %>
                <div class="rate-limit-card">
                  <p class="rate-limit-label">Primary</p>
                  <p class="rate-limit-value numeric">
                    <%= rate_limit_remaining(@payload.rate_limits, "primary") %> / <%= rate_limit_limit(@payload.rate_limits, "primary") %>
                  </p>
                </div>
              <% end %>
              <%= if rate_limit_bucket(@payload.rate_limits, "secondary") do %>
                <div class="rate-limit-card">
                  <p class="rate-limit-label">Secondary</p>
                  <p class="rate-limit-value numeric">
                    <%= rate_limit_remaining(@payload.rate_limits, "secondary") %> / <%= rate_limit_limit(@payload.rate_limits, "secondary") %>
                  </p>
                </div>
              <% end %>
              <%= if rate_limit_bucket(@payload.rate_limits, "credits") do %>
                <div class="rate-limit-card">
                  <p class="rate-limit-label">Credits</p>
                  <p class="rate-limit-value numeric">
                    <%= rate_limit_remaining(@payload.rate_limits, "credits") %> / <%= rate_limit_limit(@payload.rate_limits, "credits") %>
                  </p>
                </div>
              <% end %>
            </div>
          <% else %>
            <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
          <% end %>
        </section>

        <%!-- Event stream --%>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Event Stream</h2>
              <p class="section-copy">Live feed of agent events across all issues.</p>
            </div>
          </div>

          <%= if @events == [] do %>
            <p class="empty-state">No events recorded yet.</p>
          <% else %>
            <div class="event-stream">
              <div :for={event <- @events} class="event-row">
                <span class="event-row-time mono"><%= format_event_time(event.timestamp) %></span>
                <a class="event-row-issue" href={"/issues/#{event.issue_identifier}"}><%= event.issue_identifier %></a>
                <span class={event_type_badge_class(event.event)}>
                  <%= event.event %>
                </span>
                <span class="event-row-message"><%= event.message || "—" %></span>
                <%= if token_delta = Map.get(event, :token_delta) do %>
                  <span class="event-row-tokens mono" title="Token delta for this event">
                    +<%= Map.get(token_delta, :total, 0) %>t
                  </span>
                <% end %>
              </div>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <a class="issue-id" href={"/issues/#{entry.issue_identifier}"}><%= entry.issue_identifier %></a>
                        <span class="issue-links">
                          <a class="issue-link" href={"/issues/#{entry.issue_identifier}"}>Detail</a>
                          <a class="issue-link" href={"https://linear.app/issue/#{entry.issue_identifier}"} target="_blank">Linear</a>
                        </span>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <a class="issue-id" href={"/issues/#{entry.issue_identifier}"}><%= entry.issue_identifier %></a>
                        <span class="issue-links">
                          <a class="issue-link" href={"/issues/#{entry.issue_identifier}"}>Detail</a>
                          <a class="issue-link" href={"https://linear.app/issue/#{entry.issue_identifier}"} target="_blank">Linear</a>
                        </span>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
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
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  # Rate limit helpers

  defp rate_limit_structured?(rate_limits) when is_map(rate_limits) do
    limit_id = Map.get(rate_limits, "limit_id") || Map.get(rate_limits, :limit_id) ||
               Map.get(rate_limits, "limit_name") || Map.get(rate_limits, :limit_name)

    !is_nil(limit_id)
  end

  defp rate_limit_structured?(_), do: false

  defp rate_limit_id(rl) do
    Map.get(rl, "limit_id") || Map.get(rl, :limit_id) ||
    Map.get(rl, "limit_name") || Map.get(rl, :limit_name) || "n/a"
  end

  defp rate_limit_bucket(rl, name) do
    Map.get(rl, name) || Map.get(rl, String.to_atom(name))
  end

  defp rate_limit_remaining(rl, name) do
    bucket = rate_limit_bucket(rl, name)
    if is_map(bucket) do
      Map.get(bucket, "remaining") || Map.get(bucket, :remaining) || "n/a"
    else
      "n/a"
    end
  end

  defp rate_limit_limit(rl, name) do
    bucket = rate_limit_bucket(rl, name)
    if is_map(bucket) do
      Map.get(bucket, "limit") || Map.get(bucket, :limit) || "n/a"
    else
      "n/a"
    end
  end
end
