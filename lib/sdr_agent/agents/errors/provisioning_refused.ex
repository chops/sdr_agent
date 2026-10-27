defmodule SdrAgent.Agents.Errors.ProvisioningRefused do
  @moduledoc """
  `ModelCallGrant :provision_delegated` was refused for an attested grant
  provisioner (C2* S2; plan `claude-c2star-s2-provisioning-plan-r1.md` §5),
  and nothing was written. Class `:invalid`; `reason` is one of:

    * `:inputs_refused` — the caller supplied a server-derived private
      argument (`authorization_sha256`, `claim_nonce`, `decision_refs`),
      whatever its value;
    * `:binding_mismatch` — the live database's name or oid, or the
      creating tenant, is not the attested environment's;
    * `:authorization_invalid` — the registry entry breaks a shape rule
      (`SdrAgent.AgentEnv.Registry.validate/1`);
    * `:authorization_expired` — the entry's `expires_at` has passed;
    * `:another_authorization_provisioned` — a delegated grant of another
      authorization already exists in the tenant (OQ8);
    * `:grant_conflict` — the tenant's grant for this authorization differs
      from the entry (replay identity, OQ9); it is never repaired.
  """
  use Splode.Error, fields: [:reason], class: :invalid

  def message(%{reason: reason}), do: "delegated provisioning refused: #{reason}"
end
