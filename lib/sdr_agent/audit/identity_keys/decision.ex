defmodule SdrAgent.Audit.IdentityKeys.Decision do
  @moduledoc """
  The pure decision of an identity-key request (plan r8 section 2.4, rules
  1-9). Inputs: the application scope (`%IdentityKeys.Scope{}`: token and
  state), the membership record as read (`nil`, `""` or
  `"v1;<token>;<backend pid>;<id>,<id>,…"`), the backend pid, the set of
  ids the backend holds as granted exclusive advisory locks, and the
  requested ids (a list or a set; duplicates are one id).

  Results:

    * `:ok` (rule 3): every requested id is in this scope's recorded set,
      and the whole recorded set is held;
    * `{:acquiring, prior, planned_new}` (rule 8, or rule 6 then 8): a
      first pass is due; `prior` is the record as read (`nil` when absent
      or empty) and `planned_new` the requested set minus the held set;
    * a raise: `LateAcquisition` (rule 4) or `PassInconsistent` (rules 1,
      2, 5, 7, 9, and an unparseable or unknown-version record).

  It reads nothing and changes nothing; `SdrAgent.Audit.IdentityKeys`
  applies the result.
  """

  alias SdrAgent.Audit.IdentityKeys.LateAcquisition
  alias SdrAgent.Audit.IdentityKeys.PassInconsistent
  alias SdrAgent.Audit.IdentityKeys.Scope

  @record ~r/\Av1;([0-9a-f]{32});(\d+);((?:-?\d+(?:,-?\d+)*)?)\z/

  @doc "Decides a request; see the moduledoc."
  @spec decide(
          Scope.t(),
          String.t() | nil,
          integer(),
          MapSet.t(integer()) | [integer()],
          MapSet.t(integer()) | [integer()]
        ) :: :ok | {:acquiring, String.t() | nil, MapSet.t(integer())}
  def decide(%Scope{token: token, state: state}, setting, pid, held, requested) do
    held = MapSet.new(held)
    requested = MapSet.new(requested)
    current = present(setting)

    case state do
      :poisoned ->
        inconsistent(:poisoned)

      {:acquiring, _prior, _planned} ->
        inconsistent(:acquiring)

      {:passed, prior, new_ids} ->
        passed(token, current, prior, MapSet.new(new_ids), pid, held, requested)

      :none ->
        first(token, current, held, requested)
    end
  end

  @doc """
  Parses a membership record: `:absent` (absent or empty), `{:record,
  token, pid, ids}`, or `:unparseable`.
  """
  @spec parse(String.t() | nil) ::
          :absent | {:record, String.t(), integer(), MapSet.t(integer())} | :unparseable
  def parse(setting) do
    case present(setting) do
      nil ->
        :absent

      value ->
        case Regex.run(@record, value) do
          [_all, token, pid, ids] -> {:record, token, String.to_integer(pid), parse_ids(ids)}
          nil -> :unparseable
        end
    end
  end

  # Rules 3-7: a pass was published in this scope.
  defp passed(token, current, prior, new_ids, pid, held, requested) do
    case parse(current) do
      {:record, ^token, record_pid, manifest} ->
        own(record_pid, manifest, pid, held, requested)

      _not_own when current == prior ->
        # Rule 6: a proven revert (the convention case when new_ids is empty).
        if MapSet.disjoint?(new_ids, held),
          do: first(token, current, held, requested),
          else: inconsistent(:revert_with_held_keys)

      _foreign ->
        inconsistent(:record_replaced)
    end
  end

  defp own(record_pid, manifest, pid, held, requested) do
    cond do
      record_pid != pid -> inconsistent(:backend_mismatch)
      not MapSet.subset?(manifest, held) -> inconsistent(:manifest_not_held)
      MapSet.subset?(requested, manifest) -> :ok
      true -> raise LateAcquisition, count: MapSet.size(MapSet.difference(requested, manifest))
    end
  end

  # Rules 8 and 9: no pass in this scope yet.
  defp first(token, current, held, requested) do
    case parse(current) do
      :absent -> {:acquiring, nil, MapSet.difference(requested, held)}
      {:record, ^token, _pid, _ids} -> inconsistent(:own_record_without_pass)
      {:record, _token, _pid, _ids} -> {:acquiring, current, MapSet.difference(requested, held)}
      :unparseable -> inconsistent(:unparseable_record)
    end
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value) when is_binary(value), do: value

  defp parse_ids(""), do: MapSet.new()
  defp parse_ids(ids), do: ids |> String.split(",") |> MapSet.new(&String.to_integer/1)

  defp inconsistent(reason), do: raise(PassInconsistent, reason: reason)
end
