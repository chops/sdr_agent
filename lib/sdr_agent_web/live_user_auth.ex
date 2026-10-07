defmodule SdrAgentWeb.LiveUserAuth do
  @moduledoc """
  Helpers for authenticating users in LiveViews, and the operator console's
  `:operator` hook, which re-validates the signed-in operator on every
  event and navigation of a connected socket (`revalidate/1`).
  """

  use SdrAgentWeb, :verified_routes

  import Phoenix.Component

  @token_key "user_token"
  @token_resource SdrAgent.Accounts.Token

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
  # `current_scope` (`SdrAgentWeb.Scope`) every domain call takes its actor
  # from. A connected socket outlives the session check made at mount, so
  # every event and navigation first re-validates the operator
  # (`revalidate/1`): token present and unrevoked, user active, actor
  # re-read — a demoted operator acts with its new role, a disabled or
  # revoked one is signed out before anything reaches the domain.
  def on_mount(:operator, _params, session, socket) do
    case socket.assigns[:current_user] do
      %SdrAgent.Accounts.User{} = user ->
        {:cont,
         socket
         |> assign(:current_scope, SdrAgentWeb.Scope.for_user(user))
         |> Phoenix.LiveView.put_private(:operator_session, Map.take(session, [@token_key]))
         |> Phoenix.LiveView.attach_hook(:operator_revalidate, :handle_event, &revalidate_event/3)
         |> Phoenix.LiveView.attach_hook(
           :operator_revalidate,
           :handle_params,
           &revalidate_params/3
         )}

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

  defp revalidate_event(_event, _params, socket), do: halt_unless_valid(revalidate(socket))

  defp revalidate_params(_params, _uri, socket) do
    if Phoenix.LiveView.connected?(socket),
      do: halt_unless_valid(revalidate(socket)),
      else: {:cont, socket}
  end

  defp halt_unless_valid({:ok, socket}), do: {:cont, socket}
  defp halt_unless_valid({:error, socket}), do: {:halt, socket}

  @doc """
  Re-validates the operator of a connected console socket against the
  persisted state: the session token must verify, still be stored for the
  `user` purpose and not be revoked, and its subject must resolve to an
  active user (`get_by_subject`). On success the freshly read user replaces
  `current_user` and `current_scope` (a role change takes effect at once);
  a view restricted to some roles (`:allowed_roles`) redirects if the role
  no longer qualifies. Otherwise the socket is redirected to sign-in.
  """
  def revalidate(socket) do
    case current_operator(socket.private[:operator_session] || %{}) do
      {:ok, user} ->
        socket
        |> assign(:current_user, user)
        |> assign(:current_scope, SdrAgentWeb.Scope.for_user(user))
        |> check_role()

      :error ->
        {:error,
         socket
         |> Phoenix.LiveView.put_flash(
           :error,
           "Your session is no longer valid. Please sign in again."
         )
         |> Phoenix.LiveView.redirect(to: ~p"/sign-in")}
    end
  end

  defp current_operator(session) do
    with token when is_binary(token) <- Map.get(session, @token_key),
         {:ok, %{"sub" => subject, "jti" => jti}, _resource} <-
           AshAuthentication.Jwt.verify(token, :sdr_agent),
         false <- AshAuthentication.TokenResource.Actions.jti_revoked?(@token_resource, jti),
         {:ok, [_stored]} <-
           AshAuthentication.TokenResource.Actions.get_token(@token_resource, %{
             "jti" => jti,
             "purpose" => "user"
           }),
         {:ok, %SdrAgent.Accounts.User{status: :active} = user} <-
           AshAuthentication.subject_to_user(subject, SdrAgent.Accounts.User) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  defp check_role(socket) do
    roles = socket.assigns[:allowed_roles]

    if is_list(roles) and socket.assigns.current_scope.role not in roles do
      {:error,
       socket
       |> Phoenix.LiveView.put_flash(:error, "That view is not available for your role.")
       |> Phoenix.LiveView.redirect(to: ~p"/")}
    else
      {:ok, socket}
    end
  end
end
