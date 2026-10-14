defmodule SdrAgent.AI.ModelProfiles.Profile do
  @moduledoc """
  One reviewed model profile of the closed registry
  `SdrAgent.AI.ModelProfiles`: `id`, `adapter`, `cli_alias`,
  `resolved_model`, `cli_version` and `witness_disposition`.
  """
  @enforce_keys [:id, :adapter, :resolved_model]
  defstruct [:id, :adapter, :cli_alias, :resolved_model, :cli_version, :witness_disposition]

  @type t :: %__MODULE__{
          id: atom(),
          adapter: module(),
          cli_alias: String.t() | nil,
          resolved_model: String.t(),
          cli_version: String.t() | nil,
          witness_disposition: :reconciled | :captured_inferred | nil
        }
end
