defmodule SdrAgent.Agents.DemoException.Authorization do
  @moduledoc """
  The fields of an agent-environment authorization registry entry that the
  C2* demo exception reads (ADR-0005 C2* amendment item 2; S3 plan r2 §4.1):
  its `id`, its registry entry digest `entry_sha256` (lowercase hex-64 of
  the compiled entry, never the authorization file's digest), and its
  `starts_at` and `expires_at` bounds, which enter the effective window
  (`SdrAgent.Agents.DemoException.effective_window/3`).

  Built only by a Source's `c:SdrAgent.Agents.DemoException.Source.authorization/1`
  lookup in the compiled registry.
  """

  @enforce_keys [:id, :entry_sha256, :starts_at, :expires_at]
  defstruct [:id, :entry_sha256, :starts_at, :expires_at]

  @type t :: %__MODULE__{
          id: String.t(),
          entry_sha256: String.t(),
          starts_at: DateTime.t(),
          expires_at: DateTime.t()
        }
end
