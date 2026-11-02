defmodule SdrAgent.Discovery.PublicAddressTest do
  @moduledoc """
  Discovery RED-A (design r1 §1b, Codex review a75bde38 "Transport detail"):
  `SdrAgent.Discovery.PublicAddress.public?/1` admits only globally routable
  unicast addresses. Every loopback, private, link-local, shared (CGNAT),
  multicast, documentation, benchmark, reserved or unspecified address is
  refused, and an IPv6 address that embeds an IPv4 address (mapped,
  compatible, NAT64, 6to4) and every Teredo or other tunnel prefix is
  refused outright, whatever the embedded address (no translation path is
  ever trusted).
  """
  use ExUnit.Case, async: true

  @mod SdrAgent.Discovery.PublicAddress

  defp public?(ip) do
    assert Code.ensure_loaded?(@mod), "SdrAgent.Discovery.PublicAddress is not defined"
    Function.capture(@mod, :public?, 1).(ip)
  end

  defp ip(text) do
    {:ok, ip} = :inet.parse_address(String.to_charlist(text))
    ip
  end

  @refused_v4 ~w(
    0.0.0.0 0.1.2.3 10.0.0.1 10.255.255.255 100.64.0.1 100.127.255.254
    127.0.0.1 127.255.255.255 169.254.0.1 169.254.169.254 172.16.0.1
    172.31.255.255 192.0.0.1 192.0.2.10 192.88.99.1 192.168.1.1
    198.18.0.1 198.19.255.255 198.51.100.7 203.0.113.9 224.0.0.1
    239.255.255.250 240.0.0.1 255.255.255.255
  )

  @refused_v6 ~w(
    :: ::1 fe80::1 febf::1 fc00::1 fd12:3456::1 ff02::1 ff0e::1
    2001:db8::1 100::1 2001::1 2001:0:4136:e378::1
    ::ffff:127.0.0.1 ::ffff:10.0.0.1 ::ffff:169.254.169.254
    ::127.0.0.1 64:ff9b::a00:1 64:ff9b::7f00:1 2002:7f00:1::1 2002:a00:1::1
    ::ffff:8.8.8.8 ::8.8.8.8 64:ff9b::808:808 64:ff9b:1::1 2002:808:808::1
  )

  @admitted ~w(
    8.8.8.8 1.1.1.1 93.184.216.34 172.32.0.1 100.128.0.1 198.20.0.1
    2606:4700::1111 2a00:1450:4001::200e
  )

  test "every non-public IPv4 address is refused" do
    for a <- @refused_v4, do: refute(public?(ip(a)), a)
  end

  test "every non-public IPv6 address, including every IPv4-embedding form, is refused" do
    for a <- @refused_v6, do: refute(public?(ip(a)), a)
  end

  test "globally routable native addresses are admitted" do
    for a <- @admitted, do: assert(public?(ip(a)), a)
  end

  test "anything that is not an address tuple is refused" do
    for v <- ["8.8.8.8", nil, {8, 8, 8}, {256, 0, 0, 1}, {1, 2, 3, 4, 5, 6, 7, 65_536}, :x],
        do: refute(public?(v), inspect(v))
  end
end
