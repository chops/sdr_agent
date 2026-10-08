defmodule SdrAgentWeb.SmokeAttestation do
  @moduledoc """
  The browser smoke's server-side attestation (S13, review #25 MF2): the
  scripted browser (`test/browser/golden_path_smoke.mjs`) signs in and
  approves, so it must prove it is attached to the throw-away smoke server
  and never to the dev server (port 4120, `sdr_agent_dev`).

  `mix sdr.demo.serve` (test env, `_demo` database only) puts a fresh random
  nonce in this module's app env and writes it, with the port and database,
  to `tmp/smoke/attestation-<port>.json` (mode 0600). This plug then answers
  `GET /__smoke/attestation` with that nonce, the Repo's actual database and
  the environment; the script refuses to start the browser unless the file
  and the server agree and the database is a `sdr_agent_test*_demo` one.

  It is compiled into the endpoint only when `config :sdr_agent,
  :smoke_attestation_plug, true` (test config); with no nonce configured it
  passes the request on (the router answers 404). A dev or prod server has
  neither, so it can never attest.
  """
  @behaviour Plug

  import Plug.Conn

  @path ["__smoke", "attestation"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "GET", path_info: @path} = conn, _opts) do
    case Application.get_env(:sdr_agent, __MODULE__) do
      %{nonce: nonce} when is_binary(nonce) and byte_size(nonce) >= 32 ->
        body =
          Jason.encode!(%{
            nonce: nonce,
            database: Keyword.fetch!(SdrAgent.Repo.config(), :database),
            env: "test"
          })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)
        |> halt()

      _ ->
        conn
    end
  end

  def call(conn, _opts), do: conn
end
