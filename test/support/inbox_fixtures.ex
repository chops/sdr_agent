defmodule SdrAgent.InboxFixtures do
  @moduledoc """
  C1 read-contract fixtures. Sources and sessions are created through their
  domain APIs; the Inbox presence assertion keeps the initial RED executable
  instead of crashing on an undefined facade.
  """

  import ExUnit.Assertions
  import SdrAgent.AuditCase, only: [test_password: 0]

  alias SdrAgent.Accounts
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Operations

  @doc "A stored authenticated session, not a caller-supplied actor."
  def session!(user) do
    fixture = Enum.find(Fixtures.users(), &(&1.id == user.id))
    password = if fixture, do: fixture.password, else: test_password()
    assert {:ok, signed_in} = Accounts.sign_in(to_string(user.email), password)
    signed_in.__metadata__.token
  end

  @doc "A pending source condition, with optional typed source attributes."
  def failure!(ctx, attrs \\ %{}) do
    assert {:ok, failure} =
             Operations.open_failure(
               Map.merge(
                 %{
                   subject_resource: "SdrAgent.Sales.Lead",
                   subject_id: Ecto.UUID.generate(),
                   class: :provider_error,
                   severity: :warning,
                   message: "Synthetic provider needs attention",
                   retryable: false
                 },
                 attrs
               ),
               actor: ctx.agent
             )

    failure
  end

  @doc "Invoke the planned facade only after asserting the missing behavior."
  def refresh(session, opts \\ []) do
    assert Code.ensure_loaded?(SdrAgent.Inbox) and
             function_exported?(SdrAgent.Inbox, :refresh, 2),
           "C1-02 Inbox.refresh/2 authorized bounded projection is not implemented"

    apply(SdrAgent.Inbox, :refresh, [session, opts])
  end

  @doc "A row named by its source id, not by its opaque task identity."
  def item!(page, source) do
    assert item = Enum.find(page.items, &(&1.subject_ref.id == source.id))
    item
  end

  @doc "A ready exact nonnegative total, never an estimate or stale fallback."
  def total!(page, metric) do
    assert %{status: :ready, value: value} = Map.fetch!(page.totals, metric)
    assert is_integer(value) and value >= 0
    value
  end

  @doc "Collect the SQL executed during a refresh, including child read tasks."
  def trace_queries(fun) do
    owner = self()
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        id,
        [:sdr_agent, :repo, :query],
        fn _event, _measurements, meta, receiver ->
          send(receiver, {:inbox_query, meta.query, meta.params})
        end,
        owner
      )

    try do
      result = fun.()
      {result, drain_queries([])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain_queries(acc) do
    receive do
      {:inbox_query, sql, params} -> drain_queries([{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
