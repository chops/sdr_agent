defmodule SdrAgent.Prototype.Output do
  @moduledoc """
  The one standalone serializer of D-237 prototype business output
  (interfaces r6 IF-5, must-fix R2, Q1; amendment item 8 "Serialization").

  Two channels, never mixed:

    * the content-free channel is `SdrAgent.Prototype.SafeLog` (codes,
      counts, UUIDs and closed atoms only);
    * the ONE content-bearing channel is the private labelled bundle,
      `write_bundle/3`: a JSON file exclusive-created with mode 0600 in a
      0700 directory, never overwritten, reported only by its UUID and item
      count.

  A view is `%{"schema" => "d237-output/2", "prototype" => block, "kind" =>
  kind, "id" => uuid, "fields" => fields}` with closed `fields` per kind
  (`:run`, `:pending_revision`, `:approval`, `:receipt`). Outside prototype
  runtime `view/3` and `write_bundle/3` return
  `{:error, :not_prototype_runtime}` and serialize nothing.

  The two digests are typed and never interchangeable:

    * `check_revision/1`: the canonical `{subject, body_text}` digest
      (`SdrAgent.Audit.Canonical`, the current canonicalization version)
      equals `DraftRevision.content_sha256`;
    * `check_approval/2`: the approval names that revision, its
      `revision_content_sha256` equals the revision's `content_sha256`, and
      the revision's own check passes;
    * `check_receipt/2`: the bytes are a rendered RFC 5322 message (a header
      block, a blank line, a body) and `sha256(bytes)` equals
      `DeliveryReceipt.rendered_sha256`.

  A mismatch is `{:error, :digest_mismatch}`. Neither byte stream is
  altered, and the label never enters either.

  `task_refusal/1` is the prototype-runtime gate of Mix tasks (Codex S4 RED
  ruling 6): a CLOSED allow-list of exact names
  (`sdr.prototype.{setup,provision,import,op,serve}` and
  `sdr.audit.export`) is `:ok`; with the switch present at all
  (`SDR_PROTOTYPE` or `SDR_PROTOTYPE_INSTANCE`, even partial, empty or
  malformed) or in prototype runtime, every other task is
  `{:error, :prototype_task_refused}`. Allow-list membership grants no
  authority: each allowed task still runs its own process-kind, boot and
  operator checks. Every `run/1` clause of every other task of `lib/mix/tasks` begins
  with this terminal check, outside any rescue.

  Bounded stage (D-237 S4, Codex 9086e6a8): the prototype-runtime views and
  the bundle are not implemented yet and return `{:error, :not_implemented}`
  in prototype runtime.
  """

  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Outreach.Approval
  alias SdrAgent.Outreach.DeliveryReceipt
  alias SdrAgent.Outreach.DraftRevision
  alias SdrAgent.Prototype

  @type kind :: :run | :pending_revision | :approval | :receipt
  @type view_error ::
          :not_prototype_runtime | :binding_mismatch | :forbidden | :not_found | :digest_mismatch

  @kinds [:run, :pending_revision, :approval, :receipt]

  @allowed_tasks [
    "sdr.prototype.setup",
    "sdr.prototype.provision",
    "sdr.prototype.import",
    "sdr.prototype.op",
    "sdr.prototype.serve",
    "sdr.audit.export"
  ]

  @switch ["SDR_PROTOTYPE", "SDR_PROTOTYPE_INSTANCE"]

  @doc "The closed set of view kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The closed allow-list of Mix tasks that may start with the prototype switch set."
  @spec allowed_tasks() :: [String.t()]
  def allowed_tasks, do: @allowed_tasks

  @doc "One labelled view of `kind` for record `id`, read as `actor`."
  @spec view(kind(), Ecto.UUID.t(), SdrAgent.Actor.t()) :: {:ok, map()} | {:error, view_error()}
  def view(_kind, _id, _actor) do
    with :ok <- prototype_runtime(), do: red({:error, :not_implemented})
  end

  @doc "Writes the private labelled bundle `bundle_id` holding the views of `items`."
  @spec write_bundle([{kind(), Ecto.UUID.t()}], SdrAgent.Actor.t(), Ecto.UUID.t()) ::
          {:ok, %{bundle_id: Ecto.UUID.t(), items: non_neg_integer()}} | {:error, term()}
  def write_bundle(_items, _actor, _bundle_id) do
    with :ok <- prototype_runtime(), do: red({:error, :not_implemented})
  end

  @doc "The revision-content digest check (see the moduledoc)."
  @spec check_revision(struct()) :: :ok | {:error, :digest_mismatch}
  def check_revision(%DraftRevision{
        subject: subject,
        body_text: body,
        content_sha256: <<_::256>> = digest,
        canonicalization_version: version
      })
      when is_binary(subject) and is_binary(body) do
    if version == Canonical.version() and
         Canonical.sha256(%{subject: subject, body_text: body}) == digest,
       do: :ok,
       else: {:error, :digest_mismatch}
  end

  def check_revision(_revision), do: {:error, :digest_mismatch}

  @doc "The approval's bound digest equals its revision's `content_sha256` (see the moduledoc)."
  @spec check_approval(struct(), struct()) :: :ok | {:error, :digest_mismatch}
  def check_approval(
        %Approval{draft_revision_id: revision_id, revision_content_sha256: <<_::256>> = bound},
        %DraftRevision{id: revision_id, content_sha256: bound} = revision
      ),
      do: check_revision(revision)

  def check_approval(_approval, _revision), do: {:error, :digest_mismatch}

  @doc "The rendered-message digest check (see the moduledoc)."
  @spec check_receipt(struct(), binary()) :: :ok | {:error, :digest_mismatch}
  def check_receipt(%DeliveryReceipt{rendered_sha256: <<_::256>> = digest}, rendered)
      when is_binary(rendered) do
    if rendered_message?(rendered) and :crypto.hash(:sha256, rendered) == digest,
      do: :ok,
      else: {:error, :digest_mismatch}
  end

  def check_receipt(_receipt, _rendered), do: {:error, :digest_mismatch}

  @doc "`:ok` when Mix task `task` may run; `{:error, :prototype_task_refused}` otherwise."
  @spec task_refusal(String.t()) :: :ok | {:error, :prototype_task_refused}
  def task_refusal(task) when is_binary(task) do
    if task in @allowed_tasks or not prototype_switch?(),
      do: :ok,
      else: {:error, :prototype_task_refused}
  end

  def task_refusal(_task), do: {:error, :prototype_task_refused}

  # Startup intent is refusal-only: any presence of either switch variable,
  # even partial, empty or malformed, refuses; boot verification has not run.
  defp prototype_switch? do
    prototype_runtime?() or Enum.any?(@switch, &(System.get_env(&1) != nil))
  end

  defp prototype_runtime do
    if prototype_runtime?(), do: :ok, else: {:error, :not_prototype_runtime}
  end

  # `runtime/0` is `:ordinary | :prototype`. Asking "not ordinary" is the same
  # question, and the production build (whose facade is always `:ordinary`)
  # compiles it without a comparison the type checker knows is always false.
  defp prototype_runtime?, do: Prototype.runtime() != :ordinary

  defp rendered_message?(bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [headers, _body] -> Regex.match?(~r/\A[A-Za-z][A-Za-z0-9-]*: [^\r\n]*(\r\n|\z)/, headers)
      _ -> false
    end
  end

  # RED stub result for the not-yet-bounded prototype-runtime views, typed
  # dynamic() so callers compile against it; nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
