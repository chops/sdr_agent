defmodule SdrAgent.Discovery.RobotsTest do
  @moduledoc """
  Discovery RED-A (design r1 §1b): `SdrAgent.Discovery.Robots.allowed?/3`
  decides whether our agent token may fetch a path under a site's
  robots.txt (RFC 9309 subset): the group naming our token wins over `*`;
  within the group the longest matching Allow/Disallow rule wins, Allow on
  a tie; an empty Disallow allows; `*` and a trailing `$` are honoured;
  comments, CRLF and unknown lines are ignored. No robots file (`nil`) is
  allowed; an oversized file (over 512 KiB) disallows everything.
  """
  use ExUnit.Case, async: true

  @mod SdrAgent.Discovery.Robots
  @agent "SDR-agent-discovery"

  defp allowed?(txt, path) do
    assert Code.ensure_loaded?(@mod), "SdrAgent.Discovery.Robots is not defined"
    Function.capture(@mod, :allowed?, 3).(txt, @agent, path)
  end

  test "no robots file allows" do
    assert allowed?(nil, "/team")
  end

  test "a star group disallowing everything refuses every path" do
    txt = "User-agent: *\r\nDisallow: /\r\n"
    refute allowed?(txt, "/")
    refute allowed?(txt, "/about")
  end

  test "an empty Disallow allows everything" do
    assert allowed?("User-agent: *\nDisallow:\n", "/team")
  end

  test "our own group wins over the star group, matched case-insensitively" do
    txt = """
    # comment
    User-agent: *
    Disallow: /

    User-agent: sdr-agent-discovery
    Disallow: /private
    """

    assert allowed?(txt, "/team")
    refute allowed?(txt, "/private/x")
  end

  test "the longest matching rule wins and Allow wins a tie" do
    txt = """
    User-agent: *
    Disallow: /company
    Allow: /company/team
    Disallow: /x
    Allow: /x
    """

    refute allowed?(txt, "/company/history")
    assert allowed?(txt, "/company/team")
    assert allowed?(txt, "/x")
  end

  test "wildcards and end anchors are honoured" do
    txt = "User-agent: *\nDisallow: /*.pdf$\nDisallow: /tmp*/\n"
    refute allowed?(txt, "/files/report.pdf")
    assert allowed?(txt, "/files/report.pdf.html")
    refute allowed?(txt, "/tmpx/a")
  end

  test "rules outside any user-agent group and unknown lines are ignored" do
    txt = "Disallow: /\nSitemap: https://example.com/s.xml\nUser-agent: *\nCrawl-delay: 5\n"
    assert allowed?(txt, "/about")
  end

  test "an oversized robots file disallows everything" do
    txt = "User-agent: *\nAllow: /\n" <> String.duplicate("#", 512 * 1024)
    refute allowed?(txt, "/")
  end
end
