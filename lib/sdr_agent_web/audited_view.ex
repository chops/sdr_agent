defmodule SdrAgentWeb.AuditedView do
  @moduledoc """
  The console's audited read path (S2 "Auditor contract": every
  auditor-reachable view appends an AuditAccess naming the records shown;
  if that append fails, the page is not served — fail closed).

    * `record/4` — before an auditor is shown a view, records a
      `record_view` AuditAccess (and its AuditEvent) through
      `SdrAgent.Audit.record_access/5`. Admins and reviewers are not recorded
      for record views (S2: AuditAccess is required for every AUR view and
      for payload content).
    * `read_content/3` — payload content (captured messages, research
      sources) for any role, only through `SdrAgent.Audit.read_content/2`,
      which records a `payload_view` access first and fails closed.

  LiveViews load data only on the connected render (the disconnected render
  shows a skeleton), so an auditor's page load records exactly one access.
  """

  alias SdrAgent.Audit
  alias SdrAgentWeb.Scope

  @doc """
  Records that the scope's auditor is shown `target_ref` (one id, or a list
  of ids joined with commas; `"none"` for an empty list) of `target_resource`. Returns `:ok`, or
  `{:error, reason}` when the access could not be recorded (serve nothing).
  """
  @spec record(Scope.t(), String.t(), String.t() | [String.t()], String.t()) ::
          :ok | {:error, term()}
  def record(%Scope{} = scope, target_resource, target_ref, purpose) do
    if Scope.auditor?(scope) do
      ref =
        case target_ref do
          [] -> "none"
          ids when is_list(ids) -> Enum.join(ids, ",")
          id -> id
        end

      case Audit.record_access(:record_view, target_resource, ref, purpose, actor: scope.user) do
        {:ok, _access} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  @doc "Payload content by sha256 (binary or hex) through the audited read; `{:ok, content}` or `{:error, reason}`."
  @spec read_content(Scope.t(), binary(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_content(%Scope{} = scope, sha256, purpose) do
    sha256 = if byte_size(sha256) == 64, do: Base.decode16!(sha256, case: :mixed), else: sha256
    Audit.read_content(sha256, actor: scope.user, purpose: purpose)
  end

  @doc "An operator-facing message for a refused or invalid domain call (never raw internals)."
  @spec error_message(term()) :: String.t()
  def error_message(%Ash.Error.Forbidden{}),
    do: "Not permitted for your role. The attempt was refused and recorded."

  def error_message(%Ash.Error.Invalid{errors: errors}) do
    errors
    |> Enum.map(&invalid_message/1)
    |> Enum.uniq()
    |> Enum.join("; ")
  end

  def error_message(%Ash.Error.Query.NotFound{}), do: "Not found."
  def error_message({tag, detail}) when is_atom(tag), do: "#{humanize(tag)}: #{humanize(detail)}"
  def error_message(tag) when is_atom(tag), do: humanize(tag)
  def error_message(_other), do: "The request could not be completed."

  defp invalid_message(%{field: field, message: message} = error)
       when is_binary(message) and not is_nil(field),
       do: "#{humanize(field)} #{interpolate(message, error)}"

  defp invalid_message(%{message: message} = error) when is_binary(message),
    do: interpolate(message, error)

  defp invalid_message(error) when is_exception(error) do
    error
    |> Exception.message()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or &1 == "Bread Crumbs:" or String.starts_with?(&1, "> ")))
    |> Enum.join(" ")
  end

  defp invalid_message(_error), do: "invalid input"

  defp interpolate(message, error) do
    vars = Map.get(error, :vars) || []

    Enum.reduce(vars, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  rescue
    _ -> message
  end

  defp humanize(value) when is_atom(value) or is_binary(value),
    do: value |> to_string() |> String.replace("_", " ")

  defp humanize(value), do: inspect(value)
end
