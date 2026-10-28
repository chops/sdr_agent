defmodule SdrAgent.D237TaskAdoption do
  @moduledoc """
  The pure source check of D-237 task adoption (S1b plan r4, I2 r2): whether
  one prototype task module's source follows the boundary grammar. It
  parses the source with `Code.string_to_quoted/2` and never compiles,
  evaluates or loads it.

  The grammar, for task `kind` (one of `:setup`, `:provision`, `:import`,
  `:op`, `:serve`):

  - the file's only top-level form is an `if` on
    `Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)`
    whose `do` block is the one `defmodule` (otherwise `:not_gated`);
  - exactly one `run/1` clause (`def run(argv)`, no guard), whose body is
    exactly two expressions: `attached = SafeLog.attach(file: nil)` then
    `TaskBoundary.run(kind, attached, fn -> … end)`, with `kind` the
    literal atom for the file and the third argument a zero-arity `fn`
    literal. `SafeLog` and `TaskBoundary` may be written as the full
    `SdrAgent.Prototype.*` names or through an alias of exactly them
    (otherwise `:run_shape`; `:no_run` when there is no `run/1`);
  - the attach call is exactly `attach(file: nil)` (otherwise `:attach_form`);
  - no `@requirements` attribute (`:requirements`);
  - no call anywhere in the module to `IO.*`, `Logger.*`, `Mix.shell/0`,
    `Mix.raise/1,2`, `System.halt/0,1`, `System.stop/0,1`,
    `:erlang.halt/0,1,2`, `:init.stop/0,1`, `exit/1` or `Process.exit/2`
    (`:forbidden_call`);
  - unparsable source is `:not_parsed`.

  `violations/2` returns the sorted, unique list; `[]` means the source
  follows the grammar. It is a lexical check of the reviewed source, not a
  runtime proof: dynamic dispatch (`apply/3`, captures held in variables)
  is outside it and stays a review item. At GREEN, alias resolution is
  pinned (an alias counts only when it names exactly
  `SdrAgent.Prototype.SafeLog` or `SdrAgent.Prototype.TaskBoundary`), and
  the invalid-syntax and run-shape controls are kept; module-body effects
  beyond `use`, `alias`, attributes and definitions remain a review item.
  Task-specific grammars (for example S3's `ImportTaskSource`) are
  stricter and must pass as well.

  Deny-only declaration (D-237 S1b I2 RED): `violations/2` returns
  `[:not_implemented]`.
  """

  @type violation ::
          :not_parsed
          | :not_gated
          | :no_run
          | :run_shape
          | :attach_form
          | :requirements
          | :forbidden_call
          | :not_implemented

  @doc "The sorted, unique grammar violations of `source` for task `kind` (deny-only)."
  @spec violations(String.t(), atom()) :: [violation()]
  def violations(_source, _kind), do: red([:not_implemented])

  # Deny-only stub result, typed dynamic() so callers compile against it;
  # read-only, nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
