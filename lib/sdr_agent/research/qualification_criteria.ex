defmodule SdrAgent.Research.QualificationCriteria do
  @moduledoc """
  Embedded per-criterion verdicts of a qualification (spec §9
  QualificationResult): `company_size`, `industry`, `geography`, `persona`
  and `trigger`, each `:pass`, `:fail` or `:unknown`.
  """
  use Ash.Resource, data_layer: :embedded

  @verdicts [:pass, :fail, :unknown]

  attributes do
    for criterion <- [:company_size, :industry, :geography, :persona, :trigger] do
      attribute criterion, :atom do
        allow_nil? false
        constraints one_of: @verdicts
        public? true
      end
    end
  end
end
