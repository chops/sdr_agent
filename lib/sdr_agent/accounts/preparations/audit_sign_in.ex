defmodule SdrAgent.Accounts.Preparations.AuditSignIn do
  @moduledoc """
  Audits every password sign-in attempt (S2 User "AE"), after the read has
  finished:

    * success → `auth.sign_in.succeeded` with the user as actor; if the
      event cannot be appended the sign-in fails (fail closed);
    * failure (unknown email, wrong password, disabled user) →
      `auth.sign_in.failed` with an anonymous actor and only the sha256 of
      the submitted email (lowercased); never the password or the email.
      If that event cannot be appended, the append error is returned
      instead (still a refusal).
  """
  use Ash.Resource.Preparation

  alias SdrAgent.Audit.Kernel

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.after_transaction(query, fn query, result -> audit(query, result) end)
  end

  defp audit(%{resource: resource}, {:ok, [user]} = result) do
    case Kernel.append(event(resource, "auth.sign_in.succeeded", user.id, %{}, :authorized),
           actor: user
         ) do
      {:ok, _event} -> result
      {:error, error} -> {:error, error}
    end
  end

  defp audit(%{resource: resource} = query, result) do
    payload = %{email_sha256: email_sha256(Ash.Query.get_argument(query, :email))}

    case Kernel.append(event(resource, "auth.sign_in.failed", nil, payload, :denied), actor: nil) do
      {:ok, _event} -> result
      {:error, error} -> {:error, error}
    end
  end

  defp event(resource, type, subject_id, payload, decision) do
    %{
      event_type: type,
      category: :auth,
      subject_resource: inspect(resource),
      subject_id: subject_id,
      action: "sign_in",
      authorization: %{decision: decision, action: "#{inspect(resource)}.sign_in"},
      payload: Map.put(payload, :strategy, "password")
    }
  end

  defp email_sha256(nil), do: nil

  defp email_sha256(email) do
    email
    |> to_string()
    |> String.downcase()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
