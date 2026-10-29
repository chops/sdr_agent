defmodule SdrAgent.Prototype.ContainmentEntryTokenTest do
  @moduledoc """
  RED for the K0 entry token of `SdrAgent.Prototype.Containment`
  (D-237 S4 K0/guard RED packet r1; contract: reduced-containment plan r3
  section 2 "The token", r4 A1 and entity row "Entry token", carried by r5
  A1 and r5 entity row "Entry token").

  - `put_entry(kind)` succeeds ONLY when `kind` is in `kinds/0` and the
    calling process holds no token; it writes `{Containment, :entry} =>
    kind` in that process's dictionary. Anything else is
    `{:error, :entry_unadopted}` and never overwrites (set-once).
  - `entry/0` is `{:ok, kind}` or `{:error, :entry_unadopted}` (the r4 A1
    changed return; the held stub's doc still says "or nil").
  - The token is never inherited: the process dictionary is per process,
    and `entry/0` never consults `$callers`.

  The success value of `put_entry/1` (`:ok`) is packet OPEN item O-2.

  Every token is written in a throwaway process this module spawns, never
  in the ExUnit test process: there is no removal API, and the token dies
  with its process. No VM-global state is touched, so the module is async.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Prototype.Containment

  @key {SdrAgent.Prototype.Containment, :entry}
  @non_kinds [:export, :bogus, "import", nil, {:import}, 1, [:import]]

  # Runs `fun` in a fresh process with no `$callers`; returns
  # {:returned, value}, {:raised, kind}, :died or :timeout (never the raised
  # value).
  defp in_fresh(fun) do
    parent = self()
    tag = make_ref()
    {pid, mref} = spawn_monitor(fn -> send(parent, {tag, outcome(fun)}) end)

    receive do
      {^tag, value} ->
        Process.demonitor(mref, [:flush])
        value

      {:DOWN, ^mref, :process, ^pid, _reason} ->
        :died
    after
      5_000 ->
        Process.exit(pid, :kill)
        :timeout
    end
  end

  defp outcome(fun) do
    {:returned, fun.()}
  catch
    kind, _reason -> {:raised, kind}
  end

  # put_entry/1, then entry/0 and the raw dictionary key, in one process.
  defp observe(kind), do: {Containment.put_entry(kind), Containment.entry(), Process.get(@key)}

  # What a token-holding process and two processes it starts observe: the
  # holder's own entry/0, a plain spawned child's and a Task child's (the
  # Task child has the holder in its `$callers`).
  defp inherit_probe(kind) do
    adopted = Containment.put_entry(kind)
    holder = Containment.entry()
    plain = in_fresh(&Containment.entry/0)
    task = Task.async(&Containment.entry/0) |> Task.await(5_000)
    task_dict = Task.async(fn -> Process.get(@key) end) |> Task.await(5_000)
    {adopted, holder, plain, task, task_dict}
  end

  describe "put_entry/1 and entry/0" do
    test "each kind is adopted once in a fresh process and entry/0 returns it" do
      for kind <- Containment.kinds() do
        observed = in_fresh(fn -> observe(kind) end)

        assert observed == {:returned, {:ok, {:ok, kind}, kind}},
               "kind #{kind}: put_entry/entry/dictionary differ from the contract"
      end
    end

    test "without a token entry/0 is {:error, :entry_unadopted}" do
      assert in_fresh(&Containment.entry/0) == {:returned, {:error, :entry_unadopted}}
    end

    test "a value outside kinds/0 is refused, never raises and writes nothing" do
      for bad <- @non_kinds do
        observed = in_fresh(fn -> observe(bad) end)

        assert observed ==
                 {:returned, {{:error, :entry_unadopted}, {:error, :entry_unadopted}, nil}},
               "a non-kind was not refused cleanly: #{inspect(bad)}"
      end
    end

    test "set-once: a second put_entry refuses and never overwrites" do
      observed =
        in_fresh(fn ->
          first = Containment.put_entry(:import)
          other = Containment.put_entry(:op)
          same = Containment.put_entry(:import)
          {first, other, same, Containment.entry(), Process.get(@key)}
        end)

      assert observed ==
               {:returned,
                {:ok, {:error, :entry_unadopted}, {:error, :entry_unadopted}, {:ok, :import},
                 :import}}
    end

    test "a refused first call leaves the process able to adopt once" do
      observed =
        in_fresh(fn ->
          refused = Containment.put_entry(:export)
          adopted = Containment.put_entry(:import)
          {refused, adopted, Containment.entry()}
        end)

      assert observed == {:returned, {{:error, :entry_unadopted}, :ok, {:ok, :import}}}
    end
  end

  describe "never inherited" do
    test "a spawned process and a Task child of a token holder hold no token" do
      observed = in_fresh(fn -> inherit_probe(:import) end)

      assert observed ==
               {:returned,
                {:ok, {:ok, :import}, {:returned, {:error, :entry_unadopted}},
                 {:error, :entry_unadopted}, nil}},
             "the token was visible outside its own process"
    end

    test "the test process itself never holds a token" do
      assert Containment.entry() == {:error, :entry_unadopted}
      assert Process.get(@key) == nil
    end
  end
end
