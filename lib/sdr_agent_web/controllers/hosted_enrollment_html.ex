defmodule SdrAgentWeb.HostedEnrollmentHTML do
  @moduledoc """
  Hosted enrollment form and its isolated root. No token is rendered by the
  server, no inline scripts or third-party resources are included, and the
  empty form is unusable until the bundled fragment handoff succeeds.
  """
  use SdrAgentWeb, :html

  embed_templates "hosted_enrollment_html/*"
end
