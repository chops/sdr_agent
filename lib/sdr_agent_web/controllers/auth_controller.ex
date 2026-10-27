defmodule SdrAgentWeb.AuthController do
  @moduledoc """
  AshAuthentication callbacks for password and magic-link sign-in and for
  sign-out. Sign-in outcomes are audited by `SdrAgent.Accounts.User`'s
  sign-in actions; sign-out records `auth.signed_out` for the signed-in
  user. A magic-link request gets the same answer whether or not a link was
  mailed.
  """
  use SdrAgentWeb, :controller
  use AshAuthentication.Phoenix.Controller

  # A magic-link request answers the same whether or not a link was sent
  # (unknown, disabled or not-allowlisted addresses get nothing).
  def success(conn, {:magic_link, :request}, _user, _token), do: link_requested(conn)

  def success(conn, activity, user, _token) do
    return_to = get_session(conn, :return_to) || ~p"/"

    message =
      case activity do
        {:confirm_new_user, :confirm} -> "Your email address has now been confirmed"
        {:password, :reset} -> "Your password has successfully been reset"
        _ -> "You are now signed in"
      end

    conn
    |> delete_session(:return_to)
    |> store_in_session(user)
    # If your resource has a different name, update the assign name here (i.e :current_admin)
    |> assign(:current_user, user)
    |> put_flash(:info, message)
    |> redirect(to: return_to)
  end

  def failure(conn, {:magic_link, :request}, _reason), do: link_requested(conn)

  def failure(conn, {:magic_link, _phase}, _reason) do
    conn
    |> put_flash(:error, "That sign-in link is invalid, used or expired. Request a new one.")
    |> redirect(to: ~p"/sign-in")
  end

  def failure(conn, activity, reason) do
    message =
      case {activity, reason} do
        {_,
         %AshAuthentication.Errors.AuthenticationFailed{
           caused_by: %Ash.Error.Forbidden{
             errors: [%AshAuthentication.Errors.CannotConfirmUnconfirmedUser{}]
           }
         }} ->
          """
          You have already signed in another way, but have not confirmed your account.
          You can confirm your account using the link we sent to you, or by resetting your password.
          """

        {_,
         %AshAuthentication.Errors.AuthenticationFailed{
           caused_by: %AshAuthentication.Errors.ConfirmationRequired{}
         }} ->
          """
          An account with this email already exists. We've sent a link to that
          address - confirm it to finish linking this provider to your account.
          """

        _ ->
          "Incorrect email or password"
      end

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sign-in")
  end

  def sign_out(conn, _params) do
    return_to = get_session(conn, :return_to) || ~p"/"

    case conn.assigns[:current_user] do
      %SdrAgent.Accounts.User{} = user ->
        {:ok, _event} = SdrAgent.Accounts.record_signed_out(user)

      _ ->
        :ok
    end

    conn
    |> clear_session(:sdr_agent)
    |> put_flash(:info, "You are now signed out")
    |> redirect(to: return_to)
  end

  defp link_requested(conn) do
    conn
    |> put_flash(:info, "If that address may sign in, a sign-in link is on its way.")
    |> redirect(to: ~p"/sign-in")
  end
end
