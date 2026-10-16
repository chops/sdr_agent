defmodule SdrAgent.Agents.RunSettings.OperationalLimits do
  @moduledoc """
  Per-run ceilings the admin raises or lowers (C4 section 3.3; D-062, OQ-2;
  embedded in a `SettingsRevision`): the twelve integer fields of
  `SdrAgent.Agents.RunSettings.Safeguards.limit_rules/0`, each a whole
  number between its minimum and the sanity maximum 2,147,483,647, with the
  cross-field rules `research_max_total_source_chars ≥
  research_max_source_chars`, `research_max_model_calls ≤
  run_max_model_calls` and `research_target_seconds ≤
  research_job_limit_seconds`. An invalid value is refused, never clamped.
  A raise above the value in effect needs a per-field confirmation
  (`SdrAgent.Agents.SettingsRevision`).
  """
  use Ash.Resource, data_layer: :embedded

  validations do
    validate compare(:research_max_total_source_chars,
               greater_than_or_equal_to: :research_max_source_chars
             ),
             where: [present([:research_max_total_source_chars, :research_max_source_chars])]

    validate compare(:research_max_model_calls, less_than_or_equal_to: :run_max_model_calls),
      where: [present([:research_max_model_calls, :run_max_model_calls])]

    validate compare(:research_target_seconds,
               less_than_or_equal_to: :research_job_limit_seconds
             ),
             where: [present([:research_target_seconds, :research_job_limit_seconds])]
  end

  attributes do
    for {field, %{min: min, max: max}} <- SdrAgent.Agents.RunSettings.Safeguards.limit_rules() do
      attribute field, :integer do
        allow_nil? false
        public? true
        constraints min: min, max: max
      end
    end
  end
end
