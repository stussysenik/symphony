defmodule SymphonyElixir.EventLog do
  @moduledoc """
  In-memory ring buffer for orchestrator events.

  Stores a capped global event list (200 events) and per-issue lists (100 events each).
  Used by the dashboard and issue detail LiveViews to display real-time event streams.
  """

  use Agent

  @global_cap 200
  @per_issue_cap 100

  def start_link(_opts) do
    Agent.start_link(fn -> %{global: [], per_issue: %{}} end, name: __MODULE__)
  end

  @doc """
  Append an event to both the global ring buffer and the per-issue buffer.

  An optional fifth argument `metadata` (map) can include extra context such as
  `:token_delta`, `:modified_files`, or `:turn_number` that enriches the event
  for dashboard display without changing the core event structure.
  """
  @spec append(String.t(), atom() | String.t(), String.t() | map() | nil, DateTime.t() | String.t() | nil, map()) :: :ok
  def append(issue_identifier, event, message, timestamp, metadata \\ %{}) do
    entry =
      %{
        issue_identifier: issue_identifier,
        event: event,
        message: normalize_message(message),
        timestamp: timestamp || DateTime.utc_now()
      }
      |> Map.merge(normalize_metadata(metadata))

    Agent.update(__MODULE__, fn state ->
      global = Enum.take([entry | state.global], @global_cap)

      per_issue =
        Map.update(state.per_issue, issue_identifier, [entry], fn existing ->
          Enum.take([entry | existing], @per_issue_cap)
        end)

      %{state | global: global, per_issue: per_issue}
    end)
  end

  @doc """
  Return the last N global events, newest first.
  """
  @spec recent_events(pos_integer()) :: [map()]
  def recent_events(limit \\ 30) do
    Agent.get(__MODULE__, fn state ->
      Enum.take(state.global, limit)
    end)
  end

  @doc """
  Return the last N events for a specific issue, newest first.
  """
  @spec issue_events(String.t(), pos_integer()) :: [map()]
  def issue_events(issue_identifier, limit \\ 50) do
    Agent.get(__MODULE__, fn state ->
      state.per_issue
      |> Map.get(issue_identifier, [])
      |> Enum.take(limit)
    end)
  end

  defp normalize_message(%{message: msg}), do: normalize_message(msg)
  defp normalize_message(msg) when is_binary(msg), do: msg
  defp normalize_message(msg) when is_map(msg), do: inspect(msg, limit: 200)
  defp normalize_message(msg) when is_atom(msg), do: to_string(msg)
  defp normalize_message(nil), do: nil
  defp normalize_message(msg), do: inspect(msg, limit: 200)

  @allowed_metadata_keys [:token_delta, :modified_files, :turn_number, :duration_ms, :session_id]

  defp normalize_metadata(metadata) when is_map(metadata) do
    Map.take(metadata, @allowed_metadata_keys)
  end

  defp normalize_metadata(_metadata), do: %{}
end
