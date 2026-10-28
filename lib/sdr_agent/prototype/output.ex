defmodule SdrAgent.Prototype.Output do
  @moduledoc """
  The one standalone serializer of D-237 prototype business output
  (interfaces r6 IF-5, must-fix R2, Q1; amendment item 8 "Serialization").

  Two channels, never mixed:

    * the content-free channel is `SdrAgent.Prototype.SafeLog` (codes,
      counts, UUIDs and closed atoms only);
    * the ONE content-bearing channel is the private labelled bundle,
      `write_bundle/3`: a JSON file exclusive-created with mode 0600 under a
      0700 directory, never overwritten, reported only by its UUID and item
      count.

  A view is `%{"schema" => "d237-output/2", "prototype" => block, "kind" =>
  kind, "id" => uuid, "fields" => fields}` with closed `fields` per kind
  (`:run`, `:pending_revision`, `:approval`, `:receipt`). The two digests are
  typed and never interchangeable: the revision-content digest is compared
  only with `DraftRevision.content_sha256` (`check_revision/1`,
  `check_approval/2`), the rendered-message digest only with
  `DeliveryReceipt.rendered_sha256` (`check_receipt/2`). Neither byte stream
  is altered, and the label never enters either.

  `task_refusal/1` is the prototype-runtime allow-list of Mix tasks
  (`sdr.prototype.*` and `sdr.audit.export`): every other task of
  `lib/mix/tasks` refuses there as its first statement.

  RED stage (D-237 S4): the contract surface only; every function returns
  `{:error, :not_implemented}`.
  """

  @type kind :: :run | :pending_revision | :approval | :receipt
  @type view_error ::
          :not_prototype_runtime | :binding_mismatch | :forbidden | :not_found | :digest_mismatch

  @kinds [:run, :pending_revision, :approval, :receipt]

  @doc "The closed set of view kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "One labelled view of `kind` for record `id`, read as `actor`."
  @spec view(kind(), Ecto.UUID.t(), SdrAgent.Actor.t()) :: {:ok, map()} | {:error, view_error()}
  def view(_kind, _id, _actor), do: red({:error, :not_implemented})

  @doc "Writes the private labelled bundle `bundle_id` holding the views of `items`."
  @spec write_bundle([{kind(), Ecto.UUID.t()}], SdrAgent.Actor.t(), Ecto.UUID.t()) ::
          {:ok, %{bundle_id: Ecto.UUID.t(), items: non_neg_integer()}} | {:error, term()}
  def write_bundle(_items, _actor, _bundle_id), do: red({:error, :not_implemented})

  @doc "The revision-content digest check: canonical `{subject, body_text}` = `content_sha256`."
  @spec check_revision(struct()) :: :ok | {:error, :digest_mismatch}
  def check_revision(_revision), do: red({:error, :not_implemented})

  @doc "The approval's bound digest equals its revision's `content_sha256`."
  @spec check_approval(struct(), struct()) :: :ok | {:error, :digest_mismatch}
  def check_approval(_approval, _revision), do: red({:error, :not_implemented})

  @doc "The rendered-message digest check: `sha256(rendered)` = `DeliveryReceipt.rendered_sha256`."
  @spec check_receipt(struct(), binary()) :: :ok | {:error, :digest_mismatch}
  def check_receipt(_receipt, _rendered), do: red({:error, :not_implemented})

  @doc "`:ok` when Mix task `task` may run; `{:error, :prototype_task_refused}` otherwise."
  @spec task_refusal(String.t()) :: :ok | {:error, :prototype_task_refused}
  def task_refusal(_task), do: red({:error, :not_implemented})

  # RED stub result, typed dynamic() so callers compile against the stub
  # (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
