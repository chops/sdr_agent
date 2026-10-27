defmodule SdrAgent.Agents.Errors.DemoExceptionRefused do
  @moduledoc """
  A `:demo_exception` `SdrAgent.Agents.ModelResultRelease` decision was
  refused by the authoritative re-evaluation under the chain head (C2* S3
  plan r2 §6; ADR-0005 C2* amendment items 4-6). `code` is the first
  failing closed refusal code (`SdrAgent.Agents.DemoException.refusal_codes/0`).
  Nothing is written; `SdrAgent.Agents.ResultGate.finalize/4` rolls back with
  `{:demo_exception_refused, code}`.
  """
  use Splode.Error, fields: [:model_invocation_id, :code], class: :invalid

  def message(error) do
    "demo exception refused for model invocation #{error.model_invocation_id}: #{error.code}"
  end
end
