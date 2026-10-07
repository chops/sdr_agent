defmodule SdrAgentWeb.LiveUserAuth do
  @moduledoc """
  Helpers for authenticating users in LiveViews.
  """

  import Phoenix.Component
  use SdrAgentWeb, :verified_routes

  # This is used for nested liveviews to fetch the current user.
  # To use, place the following at the top of that liveview:
  # on_mount {SdrAgentWeb.LiveUserAuth, :current_user}
  def on_mount(:current_user, _params, session, socket) do
    {:cont, AshAuthentication.Phoenix.LiveSession.assign_new_resources(socket, session)}
  end

  def on_mount(:live_user_optional, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  def on_mount(:live_user_required, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  # The operator console: a signed-in user is required and becomes the
  # `current_scope` (`SdrAgentWeb.Scope`) every domain call takes its actor from.
  def on_mount(:operator, _params, _session, socket) do
    case socket.assigns[:current_user] do
      %SdrAgent.Accounts.User{} = user ->
        {:cont, assign(socket, :current_scope, SdrAgentWeb.Scope.for_user(user))}

      _ ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  def on_mount(:live_no_user, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end
end
