defmodule SdrAgentWeb.AuthOverrides do
  @moduledoc """
  AshAuthentication Phoenix UI overrides for the sign-in pages. The default
  banner loads its logo from another origin (ash-hq.org); it is off on the
  sign-in page and on the magic-link confirmation page, whose URL carries a
  live token, so neither page loads anything external (Codex M2, with
  `SdrAgentWeb.AuthPageHeaders`).
  """
  use AshAuthentication.Phoenix.Overrides

  override AshAuthentication.Phoenix.Components.SignIn do
    set :show_banner, false
  end

  override AshAuthentication.Phoenix.Components.MagicLink.SignIn do
    set :show_banner, false
  end
end
