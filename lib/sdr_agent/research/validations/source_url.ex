defmodule SdrAgent.Research.Validations.SourceUrl do
  @moduledoc """
  `ResearchArtifact :record`'s `source_url` rule (D-237 supplement 1 r2 §6,
  R8). In ordinary runtime it is exactly the synthetic-data guard
  `SdrAgent.Sales.Validations.Reserved` (`kind: :url`). In prototype
  runtime a real URL is allowed only because
  `SdrAgent.Research.Changes.DossierSourceBinding` then requires the
  artifact to be bound to exactly one dossier source and its bytes.
  """
  use Ash.Resource.Validation

  alias SdrAgent.Sales.Validations.Reserved

  @prototype_compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)
  @reserved [attribute: :source_url, kind: :url]

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, context), do: dispatch(changeset, context)

  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)

  if @prototype_compiled do
    defp dispatch(changeset, context) do
      if SdrAgent.Prototype.runtime() == :prototype,
        do: :ok,
        else: Reserved.validate(changeset, @reserved, context)
    end
  else
    # No prototype authority in a production build: always the Reserved check.
    defp dispatch(changeset, context), do: Reserved.validate(changeset, @reserved, context)
  end
end
