defmodule SdrAgentWeb.HostedEnrollment do
  @moduledoc """
  Presentation of the console-only hosted-owner link. The configured endpoint
  origin selects the site; the enrollment bearer appears only in its fragment,
  never a path/query or a domain dependency on the web layer. Callers must
  print this URL only on the owner's console, never log, persist or email it.
  """
  use SdrAgentWeb, :verified_routes

  @doc "Build a fragment-only enrollment URL for an owner-console token."
  def url(token) when is_binary(token) and byte_size(token) > 0 do
    origin = URI.parse(SdrAgentWeb.Endpoint.url())

    %URI{
      origin
      | path: ~p"/hosted-enrollment",
        query: nil,
        userinfo: nil,
        fragment: URI.encode_query(%{"enrollment_token" => token})
    }
    |> URI.to_string()
  end
end
