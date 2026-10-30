defmodule SdrAgent.OwnerAllowanceFixtures do
  @moduledoc """
  The exact, non-secret owner authorization for the D-269 prototype allowance.

  Tests copy these approved words into their own private scratch root; no
  real contact, runtime environment, owner database or model is accessed.
  The receipt digest is a literal independent of the production authority.
  """

  @receipt "Authorize 100 additional SDR application model-call attempts starting now, regardless of prior consumption. Replace the historical-count prerequisite for this allowance. Count failed and uncertain attempts; stop at 100. Use subscription Claude CLI only. Capture-only; no outreach.\n"
  @receipt_sha256 "9aba0a0c31bb77b547e0cdb9d0809fdd7aee00567509d53c691f66421d840a12"

  @doc "The exact owner-approved receipt bytes (including the final newline)."
  def receipt, do: @receipt

  @doc "The independently pinned digest of the exact receipt."
  def receipt_sha256, do: @receipt_sha256

  @doc "Writes a 0600 receipt in the caller's owned scratch root and returns its worksheet."
  def worksheet(root, name \\ "owner100.receipt") do
    path = Path.join(root, name)
    File.write!(path, @receipt)
    File.chmod!(path, 0o600)

    %{
      "schema" => "d237-owner-allowance/1",
      "total" => 100,
      "receipt" => %{"path" => name, "sha256" => @receipt_sha256}
    }
  end
end
