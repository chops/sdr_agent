# Compiled only with the D-237 prototype authority (config/dev.exs and
# config/test.exs); the production build does not contain this module.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.LaunchPrelude do
    @moduledoc """
    The ADR-0022 terminal launch prelude: before a prototype Mix task's
    entry token, remove the VM tooling the containment guard refuses.
    Called only by `SdrAgent.Prototype.TaskBoundary.launch/3`, after its
    input, attach, Repo and snapshot checks. Compiled only under
    `:prototype_authority_compiled`.

    `run/0`, in order, stopping at the first refusal (fail-closed, no
    rollback):

    - E. `eligibility/1` over the observed Elixir version, kernel version,
      whether `ExUnit.Server`, `Mix.Supervisor`, the started `:sdr_agent`
      application or any of `SdrAgent.Supervisor`, `SdrAgentWeb.Endpoint`,
      `SdrAgent.AI.ModelProvider.Coordinator` is present. Only the pinned
      Elixir 1.20.4 / kernel 11.0.3, Mix-launched, non-ExUnit,
      product-free VM is eligible.
    - P1, P2. For `Mix.PubSub` then `Mix.Sync.PubSub`, `child_step/2` over
      the observed `Mix.Supervisor` entry: absent is skipped, the exact
      expected entry is terminated and deleted, anything else refuses.
    - P3. One replacement formatter, `Logger.default_formatter()`, is
      computed once. `ssl_step/2` over the passively read stored
      `ssl_handler` (no handler callback runs) and the pinned ssl version:
      absent or already normalized is skipped; the exact original whose
      formatter-only replacement passes
      `SdrAgent.Prototype.Containment.logger_handler_projection/1` is
      normalized with the `:logger` handler-config update of the
      formatter key only, then re-read and accepted only when the stored
      formatter is that same value and every other stored field equals
      its value before the write; anything else refuses with no write.

    It reads no handler or child configuration beyond those fixed names
    and prints and logs nothing. `run/0` returns `:ok` or `:refused`; a
    failing supervisor or Logger call may instead raise or exit, which
    `TaskBoundary.launch/3` observes, without reading it, as an entry
    abort. The SafeLog output-call scan admits exactly this module's
    getter and formatter-only setter.
    """

    alias SdrAgent.Prototype.Containment

    @elixir "1.20.4"
    @kernel ~c"11.0.3"
    @ssl ~c"11.7.4"
    @std_destinations [:standard_io, :standard_error]
    @ssl_original_formatter {:ssl_logger, %{}}
    @ssl_filters [{:filter_non_ssl, {&:logger_filters.domain/2, {:log, :sub, [:otp, :ssl]}}}]
    @product_processes [
      SdrAgent.Supervisor,
      SdrAgentWeb.Endpoint,
      SdrAgent.AI.ModelProvider.Coordinator
    ]

    @typedoc "One fixed Mix.Supervisor child observation."
    @type child_observation :: :absent | {:present, term()} | term()

    @typedoc "The stored ssl_handler observation with the ssl application version."
    @type ssl_observation :: :absent | {:present, term(), term()} | term()

    @doc """
    Pure: `:eligible` only for exactly the six keys `elixir: "1.20.4"`,
    `kernel: ~c"11.0.3"`, `exunit: false`, `mix_supervisor: true`,
    `product_app: false` and `product_processes: false`; otherwise
    `:ineligible`.
    """
    @spec eligibility(term()) :: :eligible | :ineligible
    def eligibility(
          %{
            elixir: @elixir,
            kernel: @kernel,
            exunit: false,
            mix_supervisor: true,
            product_app: false,
            product_processes: false
          } = observed
        )
        when map_size(observed) == 6,
        do: :eligible

    def eligibility(_observed), do: :ineligible

    @doc """
    Pure: the step for one fixed `Mix.Supervisor` child. Absent is `:skip`;
    exactly `{Mix.PubSub, pid, :supervisor, [Mix.PubSub]}` or
    `{Mix.Sync.PubSub, pid, :worker, [Mix.Sync.PubSub]}` is `:teardown`;
    anything else, another id included, is `:refuse`.
    """
    @spec child_step(term(), child_observation()) :: :skip | :teardown | :refuse
    def child_step(id, :absent) when id in [Mix.PubSub, Mix.Sync.PubSub], do: :skip

    def child_step(Mix.PubSub, {:present, {Mix.PubSub, pid, :supervisor, [Mix.PubSub]}})
        when is_pid(pid),
        do: :teardown

    def child_step(
          Mix.Sync.PubSub,
          {:present, {Mix.Sync.PubSub, pid, :worker, [Mix.Sync.PubSub]}}
        )
        when is_pid(pid),
        do: :teardown

    def child_step(_id, _observed), do: :refuse

    @doc """
    Pure: the step for the stored `ssl_handler` given ONE precomputed
    `replacement` formatter. Absent is `:skip`. With ssl 11.7.4 and the
    pinned shape (seven keys; id, module, level, filter_default, filters
    and a standard destination as installed by ssl), the original
    `{:ssl_logger, %{}}` formatter is `:normalize` and a formatter equal to
    `replacement` is `:skip`, each only when the handler with `replacement`
    passes the kept projection; anything else is `:refuse`.
    """
    @spec ssl_step(ssl_observation(), term()) :: :skip | :normalize | :refuse
    def ssl_step(:absent, _replacement), do: :skip

    def ssl_step({:present, raw, @ssl}, replacement) when is_map(raw) do
      cond do
        not pinned_ssl_shape?(raw) -> :refuse
        not projects?(raw, replacement) -> :refuse
        raw.formatter == @ssl_original_formatter -> :normalize
        raw.formatter == replacement -> :skip
        true -> :refuse
      end
    end

    def ssl_step(_observed, _replacement), do: :refuse

    @doc """
    Effectful: the prelude steps E, P1, P2 and P3 of the moduledoc, in
    order. `:ok` when every step was skipped or done; `:refused` at the
    first refusal or failed effect, with no rollback. A raising or exiting
    supervisor or Logger call is not caught here (see the moduledoc).
    """
    @spec run() :: :ok | :refused
    def run do
      with :eligible <- eligibility(observe_eligibility()),
           :ok <- child(Mix.PubSub),
           :ok <- child(Mix.Sync.PubSub) do
        ssl(Logger.default_formatter())
      else
        _refused -> :refused
      end
    end

    defp pinned_ssl_shape?(raw) do
      map_size(raw) == 7 and Map.get(raw, :filters) == @ssl_filters and
        match?(
          %{
            id: :ssl_handler,
            module: :logger_std_h,
            level: :debug,
            filter_default: :stop,
            filters: _filters,
            formatter: _formatter,
            config: %{type: type}
          }
          when type in @std_destinations,
          raw
        )
    end

    defp projects?(raw, replacement),
      do:
        match?(
          {:ok, _projection},
          Containment.logger_handler_projection(%{raw | formatter: replacement})
        )

    defp observe_eligibility do
      %{
        elixir: System.version(),
        kernel: Application.spec(:kernel, :vsn),
        exunit: Process.whereis(ExUnit.Server) != nil,
        mix_supervisor: Process.whereis(Mix.Supervisor) != nil,
        product_app: List.keymember?(Application.started_applications(), :sdr_agent, 0),
        product_processes: Enum.any?(@product_processes, &(Process.whereis(&1) != nil))
      }
    end

    defp child(id) do
      case child_step(id, observe_child(id)) do
        :skip -> :ok
        :teardown -> teardown(id)
        :refuse -> :refused
      end
    end

    defp observe_child(id) do
      case Enum.filter(Supervisor.which_children(Mix.Supervisor), &(elem(&1, 0) == id)) do
        [] -> :absent
        [entry] -> {:present, entry}
        _entries -> :unknown
      end
    end

    defp teardown(id) do
      with :ok <- Supervisor.terminate_child(Mix.Supervisor, id) do
        Supervisor.delete_child(Mix.Supervisor, id)
      end
    end

    defp ssl(replacement) do
      observed = observe_ssl()

      case ssl_step(observed, replacement) do
        :skip -> :ok
        :normalize -> normalize(observed, replacement)
        :refuse -> :refused
      end
    end

    # The passive stored-map read: no handler callback runs.
    defp observe_ssl do
      case :logger_config.get(:logger, :ssl_handler) do
        {:ok, raw} -> {:present, raw, Application.spec(:ssl, :vsn)}
        {:error, {:not_found, :ssl_handler}} -> :absent
        _other -> :unknown
      end
    end

    # The write, then the re-read: only a handler still present, in the
    # pinned shape, holding the same replacement (ssl_step :skip) and with
    # every other stored field unchanged is accepted. Neither map is shown.
    defp normalize({:present, before, _vsn}, replacement) do
      with :ok <- :logger.update_handler_config(:ssl_handler, :formatter, replacement),
           {:present, now, _now_vsn} = observed <- observe_ssl(),
           :skip <- ssl_step(observed, replacement),
           true <- Map.delete(now, :formatter) == Map.delete(before, :formatter) do
        :ok
      else
        _refused -> :refused
      end
    end
  end
end
