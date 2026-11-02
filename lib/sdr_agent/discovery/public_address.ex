defmodule SdrAgent.Discovery.PublicAddress do
  @moduledoc """
  The address rule of public-web discovery: `public?/1` admits only a
  globally routable native unicast address, as an `:inet` tuple.

  Refused IPv4: 0/8, 10/8, 100.64/10 (shared), 127/8, 169.254/16, 172.16/12,
  192.0.0/24, 192.0.2/24, 192.88.99/24 (6to4 relay), 192.168/16, 198.18/15,
  198.51.100/24, 203.0.113/24, 224/4 (multicast) and 240/4 (reserved,
  including the broadcast address).

  Refused IPv6: ::/128, ::1, every IPv4-embedding form (::/96 compatible,
  ::ffff:0:0/96 mapped, 64:ff9b::/96 and 64:ff9b:1::/48 NAT64, 2002::/16
  6to4), 100::/64 (discard), 2001::/23 (IETF protocol assignments, Teredo
  included), 2001:db8::/32, fc00::/7, fe80::/10 and ff00::/8. An embedding
  form is refused whatever address it carries: no translation path is
  trusted.

  Anything else (a string, a malformed tuple) is refused.
  """

  import Bitwise

  @doc "True only for a globally routable native unicast address tuple."
  @spec public?(term()) :: boolean()
  def public?({a, b, c, d} = ip) when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
    do: not v4_refused?(ip)

  def public?({_, _, _, _, _, _, _, _} = ip) do
    if Enum.all?(Tuple.to_list(ip), &(is_integer(&1) and &1 in 0..0xFFFF)),
      do: not v6_refused?(ip),
      else: false
  end

  def public?(_other), do: false

  @v4_refused [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 88, 99, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4}
  ]

  @v6_refused [
    {{0, 0, 0, 0, 0, 0, 0, 0}, 96},
    {{0, 0, 0, 0, 0, 0xFFFF, 0, 0}, 96},
    {{0x64, 0xFF9B, 0, 0, 0, 0, 0, 0}, 96},
    {{0x64, 0xFF9B, 1, 0, 0, 0, 0, 0}, 48},
    {{0x100, 0, 0, 0, 0, 0, 0, 0}, 64},
    {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 23},
    {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32},
    {{0x2002, 0, 0, 0, 0, 0, 0, 0}, 16},
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7},
    {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10},
    {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8}
  ]

  defp v4_refused?(ip), do: Enum.any?(@v4_refused, fn {net, len} -> in?(ip, net, len, 8) end)
  defp v6_refused?(ip), do: Enum.any?(@v6_refused, fn {net, len} -> in?(ip, net, len, 16) end)

  # Prefix match of two address tuples whose elements are `width` bits wide.
  defp in?(ip, net, len, width) do
    total = tuple_size(ip) * width
    shift = total - len
    int(ip, width) >>> shift == int(net, width) >>> shift
  end

  defp int(tuple, width),
    do: tuple |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> (acc <<< width) + part end)
end
