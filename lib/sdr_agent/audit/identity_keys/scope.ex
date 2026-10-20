defmodule SdrAgent.Audit.IdentityKeys.Scope do
  @moduledoc """
  The application scope of identity keys (ADR-0009 C3-02 amendment item 1;
  plan r8 sections 2.2 and 2.3): the outermost `SdrAgent.Repo` transaction
  a process opens. Under the Ecto SQL sandbox it is a savepoint.

  `SdrAgent.Repo.prepare_transaction/2` wraps an outermost transaction
  function with `root/1`. The wrapper registers `%Scope{token, state:
  :none}` under `{SdrAgent.Audit.IdentityKeys, :scope}` in the process
  dictionary, runs the function, and in an `after` block deletes the entry
  only while it still holds its own token. An existing entry raises
  `IdentityKeys.ScopeConflict` and is never overwritten or deleted.

  `token` is 16 random bytes in lowercase hex. `state` is the process side
  of the pass (plan r8 section 2.3): `:none`, `{:acquiring, prior,
  planned_new}`, `{:passed, prior, new_ids}` or `:poisoned`, where `prior`
  is the membership record as read before the pass (`nil` when absent or
  empty) and the id collections are `MapSet`s. Only
  `SdrAgent.Audit.IdentityKeys` changes the state.
  """

  alias SdrAgent.Audit.IdentityKeys.ScopeConflict

  @key {SdrAgent.Audit.IdentityKeys, :scope}

  @enforce_keys [:token]
  defstruct [:token, state: :none]

  @type state ::
          :none
          | {:acquiring, String.t() | nil, MapSet.t(integer())}
          | {:passed, String.t() | nil, MapSet.t(integer())}
          | :poisoned
  @type t :: %__MODULE__{token: String.t(), state: state()}

  @doc """
  Wraps an outermost transaction function of arity 0 or 1 so that it runs
  in a fresh application scope; any other value is returned unchanged.
  """
  @spec root(term()) :: term()
  def root(fun) when is_function(fun, 0), do: fn -> scoped(fun) end
  def root(fun) when is_function(fun, 1), do: fn repo -> scoped(fn -> fun.(repo) end) end
  def root(other), do: other

  @doc "The current process's application scope, or `nil`."
  @spec current() :: t() | term() | nil
  def current, do: Process.get(@key)

  @doc "Replaces the state of the current scope, if it holds `token`."
  @spec put_state(String.t(), state()) :: :ok
  def put_state(token, state) do
    case Process.get(@key) do
      %__MODULE__{token: ^token} = scope -> Process.put(@key, %{scope | state: state})
      _other -> nil
    end

    :ok
  end

  defp scoped(fun) do
    token = open!()

    try do
      fun.()
    after
      close(token)
    end
  end

  defp open! do
    if Process.get(@key) != nil, do: raise(ScopeConflict)

    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    Process.put(@key, %__MODULE__{token: token, state: :none})
    token
  end

  defp close(token) do
    case Process.get(@key) do
      %__MODULE__{token: ^token} -> Process.delete(@key)
      _other -> nil
    end
  end
end
