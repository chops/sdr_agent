defmodule SdrAgent.Inbox.Binding do
  @moduledoc """
  Pure version-1 Home identities and freshness inputs shared by the
  projection and source command adapters. Performs no read, authorization
  or mutation; a matching digest never grants permission.
  """

  alias SdrAgent.Audit.Canonical

  @doc "The unchanged email Draft condition identity."
  def draft_identity(actor, id),
    do: {actor.tenant_id, :outreach_drafts, :draft_review, id, :email}

  @doc "The unchanged Failure attention identity."
  def failure_identity(actor, id),
    do: {actor.tenant_id, :operations_failures, :failure_attention, id, nil}

  @doc "Metadata protected by the source's locks, in the original v1 order."
  def draft_facts(%{draft: draft, revision: rev, contact: contact, campaign: campaign} = source) do
    {
      draft.status,
      rev.id,
      Base.encode16(rev.content_sha256, case: :lower),
      contact.id,
      to_string(contact.email),
      contact.status,
      campaign.status,
      source.suppression_refs
    }
  end

  @doc "The original v1 Failure metadata, without content or runtime authority."
  def failure_facts(failure) do
    Map.take(failure, [
      :status,
      :acknowledged_at,
      :resolved_at,
      :class,
      :severity,
      :subject_resource,
      :subject_id,
      :operation_id,
      :retryable
    ])
  end

  @doc "Sign a canonical v1 identity or freshness tuple with a server-owned key."
  def fingerprint(term, secret) do
    :crypto.mac(:hmac, :sha256, secret, Canonical.encode!({"c1-inbox/1", term}))
    |> Base.encode16(case: :lower)
  end
end
