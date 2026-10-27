defmodule SdrAgent.Agents.RunSettings.Safeguards do
  @moduledoc """
  The reviewed code registry of run-settings limit rules and of the fixed
  safeguards no setting touches (C4, `docs/product/c4/readiness.md`
  sections 3.3 and 3.4; D-062, OQ-2).

    * `version/0` — recorded on every run settings snapshot
      (`safeguards_version`); it changes only with reviewed code.
    * `limit_rules/0` — per operational limit field: its validation minimum
      and its sanity maximum (2,147,483,647, the stored signed 32-bit
      range), whether the code enforces it yet, and where. There is no
      policy ceiling: the admin raises or lowers every field in the app;
      a raise needs a per-field confirmation (`SettingsRevision`).
    * `entries/0` — the safeguards shown read-only with their reason and
      enforcing module.

  The rules apply at save only; they never rewrite or re-limit a snapshot.
  """

  @version "1"
  @int_max 2_147_483_647

  # {field, minimum, enforced_by | nil}. Consumers that have not merged are
  # `nil` ("not yet enforced"); the settings page reads this registry. B1-04
  # enforces the three source caps for runs whose definition declares
  # BuildEvidenceBundle v2 (the run page labels older runs "not enforced for
  # this run").
  @limits [
    {:run_max_model_calls, 1, "SdrAgent.Agents.AgentRun :reserve_model_call"},
    {:run_max_tool_calls, 1, "SdrAgent.Agents.AgentRun :record_tool_call"},
    {:run_max_tokens, 1, "SdrAgent.Agents.AgentRun :reserve_model_call"},
    {:research_max_search_requests, 0, nil},
    {:research_max_page_fetches, 0, nil},
    {:research_max_sources, 1, "SdrAgent.SDR.Actions.BuildEvidenceBundle"},
    {:research_max_source_chars, 500, "SdrAgent.SDR.Actions.BuildEvidenceBundle"},
    {:research_max_total_source_chars, 500, "SdrAgent.SDR.Actions.BuildEvidenceBundle"},
    {:research_max_output_tokens, 256, nil},
    {:research_max_model_calls, 1, nil},
    {:research_target_seconds, 30, nil},
    {:research_job_limit_seconds, 60, nil}
  ]

  @entries [
    %{
      name: "Captured delivery only (constraint 1)",
      reason: "No email leaves the machine; delivery is local capture.",
      enforced_by: "SdrAgent.Outreach.Delivery"
    },
    %{
      name: "Approval bound to exact recipient and revision (constraint 2)",
      reason: "A send needs a human approval of that exact draft and recipient.",
      enforced_by: "SdrAgent.Outreach.Approval"
    },
    %{
      name: "Suppression before every delivery (constraint 3)",
      reason: "A suppressed contact is never contacted; an agent never lifts it.",
      enforced_by: "SdrAgent.SDR.SuppressionCheck, SdrAgent.Outreach.Suppression"
    },
    %{
      name: "No tools, per-call attestation (constraint 5)",
      reason: "Model calls run with no tools and are attested per call.",
      enforced_by: "SdrAgent.AI.ModelProvider.ClaudeCLI"
    },
    %{
      name: "One model call at a time (D-069)",
      reason: "Provider calls are serialized.",
      enforced_by: "SdrAgent.AI.ModelProvider.Runtime"
    },
    %{
      name: "Real-model grants and allocations (C9)",
      reason: "Real model calls spend only owner-granted attempts.",
      enforced_by: "SdrAgent.Agents.Admission"
    },
    %{
      name: "200 model calls per UTC day",
      reason: "Tenant-day ceiling; configuration may only lower it.",
      enforced_by: "SdrAgent.Agents.daily_model_call_limit/0"
    },
    %{
      name: "25 sends per local day",
      reason: "Tenant-day send ceiling; configuration may only lower it.",
      enforced_by: "SdrAgent.Outreach.Compliance"
    },
    %{
      name: "Source quotas (D-102)",
      reason: "1,000 Brave requests and $5 of Exa per month.",
      enforced_by: "C5-02 source counter (not yet built)"
    },
    %{
      name: "Synthetic-data guard (constraint 7)",
      reason: "Only reserved synthetic domains until the real-data switch.",
      enforced_by: "SdrAgent.Sales.Synthetic"
    },
    %{
      name: "Unknown model outcomes never retried (D-064)",
      reason: "A call whose outcome is unknown is recorded, never repeated.",
      enforced_by: "SdrAgent.Agents.ModelInvocation, SdrAgent.SDR.Retry"
    },
    %{
      name: "Fixed research rules",
      reason: "Settings text frames, never replaces, the fixed prompt rules.",
      enforced_by: "SdrAgent.SDR.Prompts"
    }
  ]

  @doc "The safeguards registry version recorded on every snapshot."
  @spec version() :: String.t()
  def version, do: @version

  @doc "The sanity maximum of every limit field (signed 32-bit)."
  @spec int_max() :: pos_integer()
  def int_max, do: @int_max

  @doc "The twelve operational limit field names, in packet order."
  @spec limit_fields() :: [atom()]
  def limit_fields, do: Enum.map(@limits, &elem(&1, 0))

  @doc """
  The validation rule of each limit field, in packet order:
  `{field, %{min: integer, max: integer, enforced_by: String.t() | nil}}`.
  """
  @spec limit_rules() :: [{atom(), map()}]
  def limit_rules do
    Enum.map(@limits, fn {field, min, enforced_by} ->
      {field, %{min: min, max: @int_max, enforced_by: enforced_by}}
    end)
  end

  @doc "The read-only safeguard entries `%{name, reason, enforced_by}`."
  @spec entries() :: [map()]
  def entries, do: @entries
end
