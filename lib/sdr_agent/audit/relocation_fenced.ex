defmodule SdrAgent.Audit.RelocationFenced do
  @moduledoc """
  The identity-scoped relocation fence's refusal of an audit append
  (ADR-0024 decision 1; plan R2 "Final fence serialization"), class
  `:invalid`.

  `SdrAgent.Audit.Kernel` returns it from every append, after
  `Kernel.lock_head/1` and before any write, when
  `SdrAgent.Prototype.check_fence/0` refuses. Inside a domain action it is a
  changeset error, so the action and its enclosing transaction roll back
  and nothing is written. `SdrAgent.Audit.Guard.run/3`, the shared exit of
  the domain code interfaces, returns any result carrying it as the plain
  `{:error, :relocation_fenced}` (`normalize/1`). The message holds no
  value.
  """
  use Splode.Error, fields: [], class: :invalid

  def message(_error), do: "the database is relocation-fenced"

  @doc "`{:error, :relocation_fenced}` when `result` is an error carrying the refusal; else `result`."
  @spec normalize(term()) :: term()
  def normalize({:error, error} = result), do: if(fenced?(error), do: fenced(), else: result)
  def normalize(result), do: result

  @doc "The plain refusal."
  @spec fenced() :: {:error, :relocation_fenced}
  def fenced, do: {:error, :relocation_fenced}

  @doc "True when `error` is, or an Ash error class or changeset carrying, the refusal."
  @spec fenced?(term()) :: boolean()
  def fenced?(%__MODULE__{}), do: true
  def fenced?(:relocation_fenced), do: true
  def fenced?(%Ash.Changeset{errors: errors}), do: fenced?(errors)
  def fenced?(%{errors: errors}) when is_list(errors), do: fenced?(errors)
  def fenced?(%{error: error}), do: fenced?(error)
  def fenced?(errors) when is_list(errors), do: Enum.any?(errors, &fenced?/1)
  def fenced?(_other), do: false
end
