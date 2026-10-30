defmodule SdrAgent.Prototype.ClosedErrorEngineTest do
  @moduledoc """
  Behavioral proof over fresh synthetic Oban jobs only. Calls engine callbacks
  directly: no worker, producer, queue or model is started. Historical errors
  here are synthetic fixtures, not pre-existing application data. This proves
  new persisted error closure, not closure of raw exception telemetry.
  """
  use SdrAgent.DataCase, async: true

  alias Oban.Config
  alias Oban.Engines.Basic
  alias Oban.Job
  alias SdrAgent.Prototype.ClosedErrorEngine, as: Engine

  @closed "** (SdrAgent.Prototype.JobFailedError) prototype_job_failed"
  @canary "d268-synthetic-private-error"
  @history [%{"attempt" => 1, "at" => "2026-01-01T00:00:00Z", "error" => "synthetic-history"}]
  @callbacks [
    init: 2,
    put_meta: 4,
    check_meta: 3,
    refresh: 2,
    shutdown: 2,
    insert_job: 3,
    insert_job: 5,
    insert_all_jobs: 3,
    insert_all_jobs: 5,
    fetch_jobs: 3,
    stage_jobs: 3,
    prune_jobs: 3,
    rescue_jobs: 3,
    check_available: 1,
    complete_job: 2,
    discard_job: 2,
    error_job: 3,
    snooze_job: 3,
    cancel_job: 2,
    cancel_all_jobs: 2,
    delete_job: 2,
    delete_all_jobs: 2,
    retry_job: 2,
    retry_all_jobs: 2,
    update_job: 3
  ]

  setup do
    conf = %Config{repo: Repo, engine: Engine, name: __MODULE__, node: "synthetic", log: false}
    %{conf: conf}
  end

  test "all 25 callback arities are pinned, including the two absent Basic optional exports" do
    Code.ensure_loaded!(Basic)
    Code.ensure_loaded!(Engine)
    assert Enum.sort(Oban.Engine.behaviour_info(:callbacks)) == Enum.sort(@callbacks)
    optional = Oban.Engine.behaviour_info(:optional_callbacks)

    for callback = {name, arity} <- @callbacks do
      if callback in [insert_job: 5, insert_all_jobs: 5] do
        assert callback in optional
        refute function_exported?(Basic, name, arity)
        refute function_exported?(Engine, name, arity)
      else
        assert function_exported?(Basic, name, arity)
        assert function_exported?(Engine, name, arity)
      end
    end
  end

  test "init preserves Basic validation failures", %{conf: conf} do
    assert {:error, %ArgumentError{message: "missing required option :limit"}} =
             Engine.init(conf, [])
  end

  test "init and all metadata operations preserve the Basic contract", %{conf: conf} do
    assert {:ok, meta} = Engine.init(conf, limit: 2, queue: "d268_engine")
    assert meta.limit == 2
    assert meta.queue == "d268_engine"
    assert meta.name == conf.name
    assert meta.node == conf.node
    assert is_binary(meta.uuid)
    assert meta.paused == false
    assert Engine.put_meta(conf, meta, :paused, true) == Map.put(meta, :paused, true)
    assert Engine.check_meta(conf, meta, %{}) == Map.put(meta, :running, [])
    assert %{updated_at: %DateTime{}} = Engine.refresh(conf, meta)
    assert %{paused: true, shutdown_started_at: %DateTime{}} = Engine.shutdown(conf, meta)
    paused = %{meta | paused: true}
    assert {:ok, {^paused, []}} = Engine.fetch_jobs(conf, paused, %{})
  end

  test "insert returns the actual job and validation error", %{conf: conf} do
    assert {:ok, %Job{id: id} = job} = Engine.insert_job(conf, changeset(), [])
    assert Repo.get!(Job, id).args == job.args
    invalid = Job.new(%{}, worker: "Synthetic", max_attempts: 0)
    assert {:error, %Ecto.Changeset{valid?: false}} = Engine.insert_job(conf, invalid, [])
  end

  test "fetch and complete transition a fresh job and respect demand", %{conf: conf} do
    job = fresh(conf)
    {:ok, meta} = Basic.init(conf, limit: 1, queue: job.queue)
    assert {:ok, {^meta, [fetched]}} = Engine.fetch_jobs(conf, meta, %{})
    assert fetched.id == job.id
    assert fetched.state == "executing"
    assert fetched.attempt == 1
    assert {:ok, {^meta, []}} = Engine.fetch_jobs(conf, meta, %{occupied: :synthetic})
    assert :ok = Engine.complete_job(conf, fetched)
    assert %{state: "completed", completed_at: %DateTime{}} = Repo.get!(Job, job.id)
  end

  test "batch insertion and available queue lookup are real callbacks", %{conf: conf} do
    assert [%Job{} = first, %Job{} = second] =
             Engine.insert_all_jobs(conf, [changeset(), changeset()], [])

    assert first.id != second.id
    assert {:ok, queues} = Engine.check_available(conf)
    assert first.queue in queues
  end

  test "stage transitions only the supplied scheduled job", %{conf: conf} do
    job = fresh(conf, state: "scheduled", scheduled_at: old_time())
    assert {:ok, [%{id: id, state: "scheduled"}]} = Engine.stage_jobs(conf, only(job), limit: 10)
    assert id == job.id
    assert Repo.get!(Job, id).state == "available"
  end

  test "prune removes the supplied old completed synthetic job", %{conf: conf} do
    job = fresh(conf, state: "completed", scheduled_at: old_time(), completed_at: old_time())
    assert {:ok, [%{id: id}]} = Engine.prune_jobs(conf, only(job), max_age: 60, limit: 10)
    assert id == job.id
    refute Repo.get(Job, id)
  end

  test "rescue restores retryable work and discards exhausted work", %{conf: conf} do
    ready = fresh(conf, state: "executing", attempted_at: old_time(), attempt: 1, max_attempts: 3)
    spent = fresh(conf, state: "executing", attempted_at: old_time(), attempt: 3, max_attempts: 3)
    query = from j in Job, where: j.id in ^[ready.id, spent.id]
    assert {:ok, rescued} = Engine.rescue_jobs(conf, query, rescue_after: 1_000)
    assert Enum.sort(Enum.map(rescued, & &1.id)) == Enum.sort([ready.id, spent.id])
    assert Repo.get!(Job, ready.id).state == "available"
    assert Repo.get!(Job, spent.id).state == "discarded"
  end

  for callback <- [:discard_job, :error_job, :cancel_job] do
    test "#{callback} closes every nonnil error before appending and preserves history", %{
      conf: conf
    } do
      errors = [
        %{kind: :error, reason: %RuntimeError{message: @canary}, stacktrace: []},
        %{kind: :throw, reason: @canary, stacktrace: []},
        %{kind: :exit, reason: {:shutdown, @canary}, stacktrace: []},
        @canary,
        false
      ]

      for unsaved <- errors do
        job = fresh(conf, state: "executing", attempt: 2, errors: @history)
        loaded = %{job | unsaved_error: unsaved}
        args = if unquote(callback) == :error_job, do: [conf, loaded, 30], else: [conf, loaded]
        assert :ok = apply(Engine, unquote(callback), args)
        saved = Repo.get!(Job, job.id)
        expected = %{discard_job: "discarded", error_job: "retryable", cancel_job: "cancelled"}
        assert saved.state == expected[unquote(callback)]
        assert hd(saved.errors) == hd(@history)
        assert length(saved.errors) == 2
        assert List.last(saved.errors)["error"] == @closed
        assert List.last(saved.errors)["attempt"] == 2
        refute inspect(saved.errors) =~ @canary
      end
    end
  end

  test "cancel with nil keeps Basic's no-error branch and terminal-state protection", %{
    conf: conf
  } do
    for state <- ["available", "completed", "discarded", "cancelled"] do
      job = fresh(conf, state: state, errors: @history)
      assert job.unsaved_error == nil
      assert :ok = Engine.cancel_job(conf, job)
      saved = Repo.get!(Job, job.id)
      assert saved.state == if(state == "available", do: "cancelled", else: state)
      assert saved.errors == @history
    end
  end

  test "snooze, retry, update and delete preserve Basic result shapes and writes", %{conf: conf} do
    job = fresh(conf, state: "executing", attempt: 1)
    assert :ok = Engine.snooze_job(conf, job, 30)
    snoozed = Repo.get!(Job, job.id)
    assert snoozed.state == "scheduled"
    assert snoozed.attempt == 0
    assert snoozed.meta["snoozed"] == 1
    assert :ok = Engine.retry_job(conf, snoozed)
    available = Repo.get!(Job, job.id)
    assert available.state == "available"
    assert {:ok, %Job{priority: 2}} = Engine.update_job(conf, available, %{priority: 2})
    assert :ok = Engine.delete_job(conf, available)
    refute Repo.get(Job, job.id)
    assert {:error, :locked_or_not_found} = Engine.update_job(conf, available, %{priority: 1})
  end

  test "bulk cancel, retry and delete preserve selected ids", %{conf: conf} do
    job = fresh(conf)
    assert {:ok, [%{id: id}]} = Engine.cancel_all_jobs(conf, only(job))
    assert id == job.id
    assert Repo.get!(Job, id).state == "cancelled"
    assert {:ok, [%{id: ^id}]} = Engine.retry_all_jobs(conf, only(job))
    assert Repo.get!(Job, id).state == "available"
    assert {:ok, [%{id: ^id}]} = Engine.delete_all_jobs(conf, only(job))
    refute Repo.get(Job, id)
  end

  defp changeset(opts \\ []) do
    Job.new(
      %{"synthetic" => true},
      Keyword.merge([worker: "Synthetic", queue: "d268_engine"], opts)
    )
  end

  defp fresh(conf, opts \\ []) do
    {:ok, job} = Basic.insert_job(conf, changeset(opts), [])
    job
  end

  defp only(job), do: from(j in Job, where: j.id == ^job.id)
  defp old_time, do: DateTime.add(DateTime.utc_now(), -3_600)
end
