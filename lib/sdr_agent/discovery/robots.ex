defmodule SdrAgent.Discovery.Robots do
  @moduledoc """
  A bounded robots.txt decision for public-web discovery (an RFC 9309
  subset). `allowed?/3` takes the file's bytes (or `nil` for a file that is
  confirmed absent), our agent token and a path:

    * Groups start at one or more `User-agent` lines. The rules of every
      group whose token occurs (case-insensitively) in our agent token are
      combined; if there is none, the rules of every `*` group are combined;
      otherwise everything is allowed. An empty `User-agent` names nobody.
    * Within the group the longest matching `Allow`/`Disallow` pattern wins,
      `Allow` on a tie; an empty `Disallow` matches nothing. `*` matches any
      run of characters and a trailing `$` anchors the end.
    * Comments, blank lines, CRLF and any other field are ignored; rules
      before the first `User-agent` line belong to no group.
    * A file over 524_288 bytes allows nothing.

  The caller decides when `nil` applies: only a confirmed absence (404),
  never a timeout, refusal or error. This module never fetches.
  """

  @max_bytes 524_288

  @doc "Whether `agent` may fetch `path` under `robots_txt`."
  @spec allowed?(String.t() | nil, String.t(), String.t()) :: boolean()
  def allowed?(nil, _agent, _path), do: true

  def allowed?(robots_txt, _agent, _path) when byte_size(robots_txt) > @max_bytes, do: false

  def allowed?(robots_txt, agent, path) when is_binary(robots_txt) do
    groups = parse(robots_txt)
    agent = String.downcase(agent)

    own = rules_of(groups, &(&1 not in ["", "*"] and String.contains?(agent, &1)))
    rules = if own == [], do: rules_of(groups, &(&1 == "*")), else: own

    decide(rules, path)
  end

  # Every group with an agent token satisfying `match?`, combined in file order.
  defp rules_of(groups, match?) do
    for {agents, rules} <- groups, Enum.any?(agents, match?), rule <- rules, do: rule
  end

  defp decide(rules, path) do
    rules
    |> Enum.filter(fn {_kind, pattern} -> pattern != "" and matches?(pattern, path) end)
    |> Enum.max_by(fn {kind, pattern} -> {String.length(pattern), kind == :allow} end, fn ->
      nil
    end)
    |> case do
      {:disallow, _pattern} -> false
      _allow_or_none -> true
    end
  end

  defp matches?(pattern, path) do
    {body, anchored} =
      if String.ends_with?(pattern, "$"),
        do: {String.slice(pattern, 0..-2//1), true},
        else: {pattern, false}

    regex =
      body
      |> String.split("*")
      |> Enum.map_join(".*", &Regex.escape/1)

    Regex.match?(~r/\A#{regex}#{if anchored, do: "\\z", else: ""}/s, path)
  end

  # [{agents, rules}] in file order. Consecutive User-agent lines share one
  # group; a User-agent line after a rule starts a new group.
  defp parse(txt) do
    txt
    |> String.split(["\r\n", "\n", "\r"])
    |> Enum.map(&line/1)
    |> Enum.reduce({[], nil}, &group/2)
    |> then(fn {groups, current} -> Enum.reverse(close(groups, current)) end)
  end

  defp line(raw) do
    raw = raw |> String.split("#", parts: 2) |> hd() |> String.trim()

    case String.split(raw, ":", parts: 2) do
      [field, value] -> {String.downcase(String.trim(field)), String.trim(value)}
      _ -> :skip
    end
  end

  defp group({"user-agent", value}, {groups, {agents, [], :agents}}),
    do: {groups, {[String.downcase(value) | agents], [], :agents}}

  defp group({"user-agent", value}, {groups, current}),
    do: {close(groups, current), {[String.downcase(value)], [], :agents}}

  defp group({field, value}, {groups, {agents, rules, _state}})
       when field in ["allow", "disallow"] do
    kind = if field == "allow", do: :allow, else: :disallow
    {groups, {agents, [{kind, value} | rules], :rules}}
  end

  defp group(_other, acc), do: acc

  defp close(groups, nil), do: groups
  defp close(groups, {agents, rules, _state}), do: [{agents, Enum.reverse(rules)} | groups]
end
