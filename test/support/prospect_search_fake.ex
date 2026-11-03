defmodule SdrAgentWeb.ProspectSearchFake do
  @moduledoc """
  Test-only stand-in for `SdrAgent.Prototype.ProspectSearch` (ADR-0027
  contract e3f72d8c), selected by the web layer through the test-seam
  `:prospect_search_ui_adapter` env. It makes no network call.

  The owner check is the real `SdrAgent.Audit.HumanAuthority.hosted_owner?/1`,
  so revocation tests exercise the real authority. `start/2` tells the test
  process `{:fake_search_started, id, request, caller}`; the test then sends
  `{:prospect_search_result, id, outcome}` to the LiveView itself.
  `cancel/2` tells it `{:fake_search_cancelled, id, caller}`.
  """
  use Agent

  alias SdrAgent.Audit.HumanAuthority

  def start_link(test_pid) when is_pid(test_pid),
    do:
      Agent.start_link(fn -> %{test_pid: test_pid, available?: true, start: :ok, n: 0} end,
        name: __MODULE__
      )

  @doc "Sets `:available?` (boolean) or `:start` (`:ok` or `{:error, code}`)."
  def put(key, value) when key in [:available?, :start],
    do: Agent.update(__MODULE__, &Map.put(&1, key, value))

  def available?(actor), do: state().available? and authorized?(actor)

  def authorized?(actor), do: HumanAuthority.hosted_owner?(actor)

  def start(actor, request) do
    if authorized?(actor) do
      case state().start do
        :ok ->
          n = Agent.get_and_update(__MODULE__, fn s -> {s.n + 1, %{s | n: s.n + 1}} end)
          id = "fake-request-#{n}"
          send(state().test_pid, {:fake_search_started, id, request, self()})
          {:ok, id}

        {:error, code} ->
          {:error, code}
      end
    else
      {:error, :forbidden}
    end
  end

  def cancel(actor, request_id) do
    if authorized?(actor) do
      send(state().test_pid, {:fake_search_cancelled, request_id, self()})
      :ok
    else
      {:error, :forbidden}
    end
  end

  def company_context(actor, candidate, %{website_url: url, domain: domain}) do
    with true <- authorized?(actor),
         %{kind: :company, id: id, name: name} when is_binary(name) <- candidate,
         %URI{scheme: "https", host: host} when is_binary(host) <- URI.parse(url),
         true <- host == domain or String.ends_with?(host, "." <> domain) do
      {:ok, %{id: id, name: name, domain: domain, website_url: url}}
    else
      _refused -> {:error, :invalid_input}
    end
  end

  def company_context(_actor, _candidate, _input), do: {:error, :invalid_input}

  defp state, do: Agent.get(__MODULE__, & &1)
end
