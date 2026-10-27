defmodule SdrAgent.Accounts.LoginAllowlist do
  @moduledoc """
  Hosted owner-only admission (the hosted copy's declared mode).

    * `enforced?/0` — `config :sdr_agent, :login_allowlist_enforced`: `true`
      in prod; dev and test set `false` deliberately (`config/config.exs`).
      A missing key or any value but `false` counts as enforced (fail
      closed). When enforced, `SdrAgent.Accounts.Preparations.AllowlistedOnly`
      admits only listed users at the magic-link request (before a token is
      minted), both sign-in actions and every session or token resolution
      (`get_by_subject`).
    * `addresses/0` — `SDR_LOGIN_ALLOWLIST`, a comma-separated list read at
      every call: entries trimmed and lowercased, blank entries dropped. If
      any entry is not a plausible single address (exactly one `@`, both
      sides non-empty, no whitespace), the whole list is invalid and admits
      nobody; so does a missing or empty one.
    * `listed?/1` — whether an address is on the (valid) list now, whatever
      the mode; the magic-link sender mails only listed addresses.
  """

  @address ~r/\A[^\s@,]+@[^\s@,]+\z/

  @doc "Whether the hosted allowlist is enforced (anything but an explicit `false`)."
  @spec enforced?() :: boolean()
  def enforced? do
    case Application.fetch_env(:sdr_agent, :login_allowlist_enforced) do
      {:ok, false} -> false
      _missing_or_other -> true
    end
  end

  @doc "The lowercased addresses on `SDR_LOGIN_ALLOWLIST` now; `[]` when it is missing, empty or invalid."
  @spec addresses() :: [String.t()]
  def addresses do
    entries =
      (System.get_env("SDR_LOGIN_ALLOWLIST") || "")
      |> String.split(",")
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      |> Enum.reject(&(&1 == ""))

    if Enum.all?(entries, &Regex.match?(@address, &1)), do: entries, else: []
  end

  @doc "Whether `email` (lowercased, trimmed) is on the list now."
  @spec listed?(String.t() | Ash.CiString.t()) :: boolean()
  def listed?(email),
    do: (email |> to_string() |> String.trim() |> String.downcase()) in addresses()
end
