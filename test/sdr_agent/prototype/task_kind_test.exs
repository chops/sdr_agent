defmodule SdrAgent.Prototype.TaskKindTest do
  @moduledoc """
  IF-2 process kinds (interfaces r6; ruling 1): the task entry fixes the
  runtime before any read and creates the session delegation; an enqueuing
  task starts an insert-only Oban (no queues, plugins, peer or stager), so
  no job executes outside serve.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Prototype.Session

  test "the insert-only Oban options are exactly ruling 1's" do
    assert Session.oban_insert_only_opts() ==
             [queues: false, plugins: false, peer: false, stage_interval: :infinity]
  end

  test "an insert-only Oban has no stager and no queue producer" do
    name = Module.concat(__MODULE__, "InsertOnly#{System.unique_integer([:positive])}")
    opts = [name: name, repo: Repo, testing: :disabled] ++ Session.oban_insert_only_opts()
    pid = start_supervised!({Oban, opts})
    assert Process.alive?(pid)
    assert Oban.Registry.whereis(name, Oban.Stager) == nil
    assert Oban.config(name).queues == []
    assert Oban.config(name).plugins == []
  end

  test "the task entry refuses outside prototype runtime" do
    assert Session.enter(agent: "claude_code", session_correlation: "task-entry-ordinary-1") ==
             {:error, :not_prototype_runtime}
  end

  test "the task entry refuses an unknown agent and a missing correlation" do
    bound!()

    assert Session.enter(agent: "other", session_correlation: "task-entry-0002") ==
             {:error, :invalid_agent}

    assert Session.enter(agent: "codex_cli", session_correlation: nil) == {:error, :session_unset}
  end

  test "the task entry returns the operator actor of its own delegation" do
    fx = bound!()
    result = Session.enter(agent: "codex_cli", session_correlation: "task-entry-0003")
    assert match?({:ok, %{}}, result), "task entry: #{inspect(result)}"
    {:ok, entered} = result

    assert entered.binding == fx.snapshot
    assert entered.actor.type == :prototype_operator
    assert entered.actor.id == entered.delegation_id
    assert entered.actor.tenant_id == fx.tenant.id
    assert entered.delegation_id != fx.delegation.id
    assert SdrAgent.Prototype.operator?(entered.actor)
  end
end
