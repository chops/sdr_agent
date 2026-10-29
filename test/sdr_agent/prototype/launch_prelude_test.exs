defmodule SdrAgent.Prototype.LaunchPreludeTest do
  @moduledoc """
  The pure decisions of the ADR-0022 terminal launch prelude (setup fix
  plan r4, Codex 0a2891ea; owner acceptance debf72c2), over constructed
  observations only. Nothing here reads or changes the VM's Mix children
  or Logger handlers.

  - `eligibility/1`: only the exact pinned, non-ExUnit, Mix-launched,
    product-free observation is `:eligible`; every other or malformed
    observation is `:ineligible`.
  - `child_step/2`: for the two fixed Mix.Supervisor children, absent is
    `:skip`, the exact expected entry is `:teardown`, anything else
    (another id, type, modules list or a non-pid) is `:refuse`.
  - `ssl_step/2`: takes the observation and ONE precomputed replacement
    formatter (the adapter computes it once and uses the same value for
    the preflight, the write and the re-read check; Codex 57d6beca).
    Absent is `:skip`; the exact pinned original `ssl_handler` whose
    formatter-only replacement passes the kept projection is `:normalize`;
    one whose formatter already equals the replacement is `:skip`; any
    other shape, version, formatter or a replacement the projection
    refuses is `:refuse` (no write-then-refuse).

  The replacement here is a deterministic synthetic formatter built with
  every option explicit, so no decision depends on shared Logger
  configuration. The module is reached through a dynamic call, so a build
  without it compiles and every case fails on the missing function, not
  on setup.
  """
  use ExUnit.Case, async: true

  @prelude SdrAgent.Prototype.LaunchPrelude

  @eligible %{
    elixir: "1.20.4",
    kernel: ~c"11.0.3",
    exunit: false,
    mix_supervisor: true,
    product_app: false,
    product_processes: false
  }

  @ssl_filter {:filter_non_ssl, {&:logger_filters.domain/2, {:log, :sub, [:otp, :ssl]}}}

  @ssl_original %{
    id: :ssl_handler,
    module: :logger_std_h,
    level: :debug,
    filter_default: :stop,
    filters: [@ssl_filter],
    formatter: {:ssl_logger, %{}},
    config: %{type: :standard_io}
  }

  defp call(fun, args) do
    if Code.ensure_loaded?(@prelude) and function_exported?(@prelude, fun, length(args)),
      do: {:ok, apply(@prelude, fun, args)},
      else: :missing
  end

  # Every option explicit: Logger.Formatter.new/1 reads application config
  # only for an omitted :truncate or :utc_log.
  defp replacement(format \\ "$message\n") do
    Logger.Formatter.new(
      format: format,
      metadata: [],
      colors: [enabled: false],
      truncate: 8096,
      utc_log: false
    )
  end

  describe "eligibility/1" do
    test "the exact pinned terminal observation is eligible" do
      assert call(:eligibility, [@eligible]) == {:ok, :eligible}
    end

    test "each single deviation is ineligible" do
      deviations = [
        elixir: "1.20.5",
        kernel: ~c"11.0.4",
        exunit: true,
        mix_supervisor: false,
        product_app: true,
        product_processes: true
      ]

      for {key, value} <- deviations do
        assert call(:eligibility, [Map.put(@eligible, key, value)]) == {:ok, :ineligible},
               "not ineligible: #{key}"
      end
    end

    test "a malformed observation is ineligible" do
      for observed <- [
            nil,
            %{},
            Map.delete(@eligible, :exunit),
            Map.put(@eligible, :extra, true),
            Map.put(@eligible, :exunit, nil),
            Map.to_list(@eligible)
          ] do
        assert call(:eligibility, [observed]) == {:ok, :ineligible}
      end
    end
  end

  describe "child_step/2" do
    test "absent is skip and the exact expected entry is teardown" do
      pid = self()
      assert call(:child_step, [Mix.PubSub, :absent]) == {:ok, :skip}
      assert call(:child_step, [Mix.Sync.PubSub, :absent]) == {:ok, :skip}

      assert call(:child_step, [
               Mix.PubSub,
               {:present, {Mix.PubSub, pid, :supervisor, [Mix.PubSub]}}
             ]) ==
               {:ok, :teardown}

      assert call(:child_step, [
               Mix.Sync.PubSub,
               {:present, {Mix.Sync.PubSub, pid, :worker, [Mix.Sync.PubSub]}}
             ]) == {:ok, :teardown}
    end

    test "any other id, type, modules list, pid or form is refuse" do
      pid = self()

      cases = [
        {Mix.State, :absent},
        {Mix.PubSub, {:present, {Mix.PubSub, pid, :worker, [Mix.PubSub]}}},
        {Mix.PubSub, {:present, {Mix.PubSub, pid, :supervisor, :dynamic}}},
        {Mix.PubSub, {:present, {Mix.PubSub, :restarting, :supervisor, [Mix.PubSub]}}},
        {Mix.PubSub, {:present, {Mix.Sync.PubSub, pid, :supervisor, [Mix.PubSub]}}},
        {Mix.Sync.PubSub, {:present, {Mix.Sync.PubSub, pid, :supervisor, [Mix.Sync.PubSub]}}},
        {Mix.Sync.PubSub, {:present, {Mix.Sync.PubSub, :undefined, :worker, [Mix.Sync.PubSub]}}},
        {Mix.Sync.PubSub, :unknown},
        {Mix.Sync.PubSub, nil}
      ]

      for {id, observed} <- cases do
        assert call(:child_step, [id, observed]) == {:ok, :refuse}
      end
    end
  end

  describe "ssl_step/2" do
    test "absent is skip" do
      assert call(:ssl_step, [:absent, replacement()]) == {:ok, :skip}
    end

    test "the exact pinned original is normalize" do
      assert call(:ssl_step, [{:present, @ssl_original, ~c"11.7.4"}, replacement()]) ==
               {:ok, :normalize}
    end

    test "a handler whose formatter already equals the replacement is skip" do
      normalized = %{@ssl_original | formatter: replacement()}
      assert call(:ssl_step, [{:present, normalized, ~c"11.7.4"}, replacement()]) == {:ok, :skip}
    end

    test "any other version, field, formatter or a refused replacement is refuse" do
      closure = {:filter_non_ssl, {fn _event, _config -> :ignore end, []}}
      original = {:present, @ssl_original, ~c"11.7.4"}

      cases = [
        {{:present, @ssl_original, ~c"11.7.5"}, replacement()},
        {{:present, %{@ssl_original | module: :logger_disk_log_h}, ~c"11.7.4"}, replacement()},
        {{:present, %{@ssl_original | id: :other_handler}, ~c"11.7.4"}, replacement()},
        {{:present, %{@ssl_original | level: :info}, ~c"11.7.4"}, replacement()},
        {{:present, %{@ssl_original | filter_default: :log}, ~c"11.7.4"}, replacement()},
        {{:present, %{@ssl_original | formatter: {:ssl_logger, %{depth: 5}}}, ~c"11.7.4"},
         replacement()},
        {{:present, %{@ssl_original | formatter: {:other_formatter, %{}}}, ~c"11.7.4"},
         replacement()},
        # A Logger.Formatter that is not the replacement: neither original nor normalized.
        {{:present, %{@ssl_original | formatter: replacement("$level $message\n")}, ~c"11.7.4"},
         replacement()},
        {{:present, %{@ssl_original | config: %{type: {:file, ~c"/tmp/x.log"}}}, ~c"11.7.4"},
         replacement()},
        {{:present, %{@ssl_original | filters: [closure]}, ~c"11.7.4"}, replacement()},
        {{:present, Map.put(@ssl_original, :extra, 1), ~c"11.7.4"}, replacement()},
        {{:present, :not_a_map, ~c"11.7.4"}, replacement()},
        {:unknown, replacement()},
        {nil, replacement()},
        # Replacements the kept projection refuses: no write-then-refuse.
        {original, {:ssl_logger, %{}}},
        {original, {:logger_formatter, %{}}},
        {original, nil}
      ]

      for {observed, candidate} <- cases do
        assert call(:ssl_step, [observed, candidate]) == {:ok, :refuse}
      end
    end
  end
end
