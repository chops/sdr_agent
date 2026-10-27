defmodule SdrAgent.Agents.Checks.DemoExceptionUse do
  @moduledoc """
  Field-policy filter check and process-bound registration for the output
  of a C2* demo-exception release (S3 plan r2 §6, OQ1; ADR-0005 C2* item 9).

  `with_use/3` registers `{tenant_id, invocation_id}` under a fresh
  reference in the CALLING process's dictionary, runs `fun.(ref)` and
  removes the registration on every exit (return, raise, throw, exit).
  `SdrAgent.Agents.ReleasedOutput.fetch/2` calls it only after
  `SdrAgent.Agents.DemoException.use_authority/3` returned `:ok`, and reads
  the invocation with `context/1` of that reference.

  The check (after `ReleasedOutputRead`'s mark in the
  `ModelInvocation` output field policy) admits the row only when the
  query context carries a reference registered in this process for the
  actor's tenant: then exactly that invocation, and only while it has a
  `:demo_exception` release. A copied, forged or stale reference, another
  process or another tenant gets `false`.
  """
  use Ash.Policy.FilterCheck

  require Ash.Expr

  @key :sdr_demo_exception_use

  @impl true
  def describe(_opts), do: "a registered demo-exception output use"

  @impl true
  def filter(%{tenant_id: tenant_id}, %{query: %{context: %{@key => ref}}}, _opts)
      when is_reference(ref) and is_binary(tenant_id) do
    case Process.get({__MODULE__, ref}) do
      {^tenant_id, invocation_id} ->
        Ash.Expr.expr(
          id == ^invocation_id and exists(result_release, disposition == :demo_exception)
        )

      _unregistered ->
        Ash.Expr.expr(false)
    end
  end

  def filter(_actor, _context, _opts), do: Ash.Expr.expr(false)

  @doc "Runs `fun.(ref)` with `{tenant_id, invocation_id}` registered under `ref` in this process."
  @spec with_use(Ecto.UUID.t(), Ecto.UUID.t(), (reference() -> result)) :: result
        when result: term()
  def with_use(tenant_id, invocation_id, fun)
      when is_binary(tenant_id) and is_binary(invocation_id) and is_function(fun, 1) do
    ref = make_ref()
    Process.put({__MODULE__, ref}, {tenant_id, invocation_id})

    try do
      fun.(ref)
    after
      Process.delete({__MODULE__, ref})
    end
  end

  @doc "The query context naming the registration `ref`."
  @spec context(reference()) :: map()
  def context(ref) when is_reference(ref), do: %{@key => ref}
end
