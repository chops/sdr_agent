defmodule SdrAgent.Outreach.Diff do
  @moduledoc """
  Line diff between two message versions (S2 DraftRevision
  `diff_from_parent` / `diff_from_ai_baseline`; ADR-0002 "a stored diff
  records AI-proposed versus human-final content").

  A version is rendered as `"Subject: <subject>"`, a blank line and the body;
  the diff (`List.myers_difference/2` over lines) prefixes removed lines with
  `-`, added lines with `+` and unchanged lines with a space, one per line.
  Deterministic: the same two versions always give the same bytes.
  """

  @doc "The text form of a version that diffs compare."
  @spec text(%{subject: String.t(), body_text: String.t()}) :: String.t()
  def text(%{subject: subject, body_text: body}), do: "Subject: #{subject}\n\n#{body}"

  @doc "Line diff from version `old` to version `new` (maps with `subject`, `body_text`)."
  @spec lines(map(), map()) :: String.t()
  def lines(old, new) do
    old
    |> text()
    |> String.split("\n")
    |> List.myers_difference(String.split(text(new), "\n"))
    |> Enum.flat_map(fn {op, lines} -> Enum.map(lines, &(prefix(op) <> &1)) end)
    |> Enum.join("\n")
  end

  defp prefix(:eq), do: " "
  defp prefix(:del), do: "-"
  defp prefix(:ins), do: "+"
end
