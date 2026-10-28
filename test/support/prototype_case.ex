defmodule SdrAgent.PrototypeCase do
  @moduledoc """
  Test case for the D-237 prototype: the sandboxed database and helpers of
  `SdrAgent.AuditCase`, plus guards that turn an absent contract into an
  assertion failure (never a compile warning or a crash):

  - `bound!/1` asserts that `SdrAgent.PrototypeFixtures.bind/1` (the real
    bootstrap path) succeeded and returns the fixture; a failure there is a
    prerequisite failure, never evidence about the test's named behaviour;
  - `loaded!/1` asserts that a module exists;
  - `call/3` calls a function of a module that may not exist yet
    (`Function.capture/3`), after `loaded!/1` and an export check.

  Prototype tests are `async: false`: the runtime they enter is
  process-scoped, but the binding row is a database singleton.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import SdrAgent.AuditCase
      import SdrAgent.PrototypeCase
      alias SdrAgent.PrototypeFixtures
      alias SdrAgent.Repo
    end
  end

  setup tags do
    SdrAgent.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc "Binds a prototype (`SdrAgent.PrototypeFixtures.bind/1`) or fails the test."
  def bound!(opts \\ []) do
    result = SdrAgent.PrototypeFixtures.bind(opts)

    ExUnit.Assertions.assert(
      match?({:ok, %{}}, result),
      "prerequisite: the prototype binding fixture (the real bootstrap, snapshot, " <>
        "seam and resolver path) returned #{inspect(result)}"
    )

    {:ok, fixture} = result
    fixture
  end

  @doc """
  Enters prototype runtime with a bound fixture's snapshot, or fails the
  test as a prerequisite. Arrange users before calling it: prototype runtime
  refuses user administration for every actor.
  """
  def enter!(fixture) do
    result = SdrAgent.PrototypeFixtures.enter_runtime(fixture.snapshot)

    ExUnit.Assertions.assert(
      result == :ok,
      "prerequisite: enter_runtime returned #{inspect(result)}"
    )

    fixture
  end

  @doc "Asserts that `module` exists."
  def loaded!(module) do
    ExUnit.Assertions.assert(Code.ensure_loaded?(module), "#{inspect(module)} does not exist")
    module
  end

  @doc "Calls `module.fun(args...)` after asserting that it exists and is exported."
  def call(module, fun, args) do
    loaded!(module)
    arity = length(args)

    ExUnit.Assertions.assert(
      function_exported?(module, fun, arity),
      "#{inspect(module)}.#{fun}/#{arity} is not exported"
    )

    Kernel.apply(Function.capture(module, fun, arity), args)
  end
end
