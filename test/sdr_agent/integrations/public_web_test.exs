defmodule SdrAgent.Integrations.PublicWebTest do
  @moduledoc """
  Discovery RED-A (design r1 §1b, Codex review a75bde38): the policy layer
  of `SdrAgent.Integrations.PublicWeb.fetch/2`, with the resolver and the
  request injected (`resolver:`, `request:`), so no test touches the
  network.

    * URL rule: the dossier's own (`DossierParser.Rules.url/2`): https, no
      port, userinfo, query, fragment, IP literal or special-use host.
    * Every resolved address must be public
      (`SdrAgent.Discovery.PublicAddress`); the request is made to the
      first resolved address, pinned, with the original host name (the
      transport uses it for Host, SNI and certificate verification), so no
      second resolution can happen inside the request.
    * Redirects (301/302/303/307/308): at most 3; each Location is resolved
      against the current URL, must pass the URL rule, and its host is
      resolved and checked again.
    * Bounds: a body over 524_288 bytes is `:too_large`; only text/html and
      text/plain are read; any other final status is `:http_status`.
    * The page carries the requested `url`, the `final_url`, the `<title>`
      text, the verbatim `content`, its `content_sha256` (lowercase hex),
      `content_type`, `published_at: nil`, `source_type: :company_site` and
      `trust_level: :unverified`.

  Errors are closed atoms and never echo a URL or body.
  """
  use ExUnit.Case, async: true

  @mod SdrAgent.Integrations.PublicWeb
  @max 524_288

  defp fetch(url, opts) do
    assert Code.ensure_loaded?(@mod), "SdrAgent.Integrations.PublicWeb is not defined"
    Function.capture(@mod, :fetch, 2).(url, opts)
  end

  defp resolver(map) do
    fn host ->
      send(self(), {:resolved, host})
      Map.get(map, host, {:error, :nxdomain})
    end
  end

  defp request(routes) do
    fn ip, host, path ->
      send(self(), {:requested, ip, host, path})
      Map.get(routes, {host, path}, {:error, :closed})
    end
  end

  defp html(body, status \\ 200),
    do:
      {:ok,
       %{status: status, headers: [{"content-type", "text/html; charset=utf-8"}], body: body}}

  defp redirect(location, status \\ 301),
    do: {:ok, %{status: status, headers: [{"location", location}], body: ""}}

  @public {93, 184, 216, 34}
  @other {93, 184, 216, 35}

  test "fetches a public page pinned to the resolved address with the original host" do
    body = "<html><head><title> Acme Team </title></head><body>Jane Roe</body></html>"

    assert {:ok, page} =
             fetch("https://www.acme.example.com/team",
               resolver: resolver(%{"www.acme.example.com" => {:ok, [@public]}}),
               request: request(%{{"www.acme.example.com", "/team"} => html(body)})
             )

    assert_received {:requested, @public, "www.acme.example.com", "/team"}
    assert page.url == "https://www.acme.example.com/team"
    assert page.final_url == "https://www.acme.example.com/team"
    assert page.title == "Acme Team"
    assert page.content == body
    assert page.content_sha256 == Base.encode16(:crypto.hash(:sha256, body), case: :lower)
    assert page.content_type == "text/html"
    assert page.published_at == nil
    assert page.source_type == :company_site
    assert page.trust_level == :unverified
  end

  test "unsafe URLs are refused before any resolution" do
    for url <- [
          "http://acme.example.com/",
          "https://acme.example.com:443/",
          "https://user@acme.example.com/",
          "https://acme.example.com/?q=1",
          "https://acme.example.com/#x",
          "https://93.184.216.34/",
          "https://[2606:4700::1111]/",
          "https://localhost/",
          "https://intranet/",
          "https://ACME.example.com/",
          "https://router.internal/",
          "ftp://acme.example.com/"
        ] do
      assert fetch(url, resolver: resolver(%{}), request: request(%{})) == {:error, :unsafe_url},
             url
    end

    refute_received {:resolved, _}
  end

  test "any non-public resolved address refuses before the request" do
    for addrs <- [
          [{127, 0, 0, 1}],
          [@public, {10, 0, 0, 1}],
          [{0, 0, 0, 0, 0, 65_535, 32_512, 1}]
        ] do
      assert fetch("https://acme.example.com/",
               resolver: resolver(%{"acme.example.com" => {:ok, addrs}}),
               request: request(%{{"acme.example.com", "/"} => html("x")})
             ) == {:error, :address_not_public}
    end

    refute_received {:requested, _, _, _}
  end

  test "a failed or empty resolution is :resolve_failed" do
    for r <- [{:error, :nxdomain}, {:ok, []}] do
      assert fetch("https://acme.example.com/",
               resolver: resolver(%{"acme.example.com" => r}),
               request: request(%{})
             ) == {:error, :resolve_failed}
    end
  end

  test "a redirect to another host is re-resolved and re-checked" do
    res =
      resolver(%{
        "acme.example.com" => {:ok, [@public]},
        "evil.example.net" => {:ok, [{169, 254, 169, 254}]}
      })

    assert fetch("https://acme.example.com/",
             resolver: res,
             request:
               request(%{{"acme.example.com", "/"} => redirect("https://evil.example.net/meta")})
           ) == {:error, :address_not_public}

    assert_received {:resolved, "evil.example.net"}
    refute_received {:requested, _, "evil.example.net", _}
  end

  test "relative redirects resolve against the current URL and record the final URL" do
    res =
      resolver(%{
        "acme.example.com" => {:ok, [@public]},
        "www.acme.example.com" => {:ok, [@other]}
      })

    routes = %{
      {"acme.example.com", "/"} => redirect("https://www.acme.example.com/", 308),
      {"www.acme.example.com", "/"} => redirect("/about", 302),
      {"www.acme.example.com", "/about"} => html("<title>About</title>")
    }

    assert {:ok, page} =
             fetch("https://acme.example.com/", resolver: res, request: request(routes))

    assert page.url == "https://acme.example.com/"
    assert page.final_url == "https://www.acme.example.com/about"
    assert_received {:requested, @other, "www.acme.example.com", "/about"}
  end

  test "unsafe redirect targets are :redirect_invalid" do
    res = resolver(%{"acme.example.com" => {:ok, [@public]}})

    for loc <- [
          "http://acme.example.com/",
          "https://10.0.0.1/",
          "https://acme.example.com/?a=1",
          ""
        ] do
      assert fetch("https://acme.example.com/",
               resolver: res,
               request: request(%{{"acme.example.com", "/"} => redirect(loc)})
             ) == {:error, :redirect_invalid},
             loc
    end
  end

  test "a fourth redirect is :too_many_redirects" do
    res = resolver(%{"acme.example.com" => {:ok, [@public]}})

    routes = %{
      {"acme.example.com", "/"} => redirect("/1"),
      {"acme.example.com", "/1"} => redirect("/2"),
      {"acme.example.com", "/2"} => redirect("/3"),
      {"acme.example.com", "/3"} => redirect("/4"),
      {"acme.example.com", "/4"} => html("x")
    }

    assert fetch("https://acme.example.com/", resolver: res, request: request(routes)) ==
             {:error, :too_many_redirects}

    refute_received {:requested, _, _, "/4"}
  end

  test "bounds: size, content type and status" do
    res = resolver(%{"acme.example.com" => {:ok, [@public]}})
    at_max = String.duplicate("a", @max)

    go = fn r ->
      fetch("https://acme.example.com/",
        resolver: res,
        request: request(%{{"acme.example.com", "/"} => r})
      )
    end

    assert {:ok, %{content: ^at_max}} = go.(html(at_max))
    assert go.(html(at_max <> "a")) == {:error, :too_large}

    assert go.(
             {:ok, %{status: 200, headers: [{"content-type", "application/pdf"}], body: "%PDF"}}
           ) ==
             {:error, :unsupported_content}

    assert go.({:ok, %{status: 200, headers: [], body: "x"}}) == {:error, :unsupported_content}

    assert {:ok, %{content_type: "text/plain"}} =
             go.({:ok, %{status: 200, headers: [{"Content-Type", "TEXT/PLAIN"}], body: "x"}})

    assert go.(html("gone", 404)) == {:error, :http_status}
    assert go.({:error, :timeout}) == {:error, :transport_failed}
  end
end
