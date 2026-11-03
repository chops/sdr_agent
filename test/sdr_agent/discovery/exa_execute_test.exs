defmodule SdrAgent.Discovery.ExaExecuteTest do
  use ExUnit.Case, async: false

  @client SdrAgent.Discovery.ExaClient
  @transport SdrAgent.Discovery.ExaTransport

  setup do
    keys = [:prospect_search_req_options, :prospect_search_test_key]
    old = Enum.map(keys, &{&1, Application.fetch_env(:sdr_agent, &1)})
    Application.put_env(:sdr_agent, :prospect_search_req_options, plug: {Req.Test, @transport})
    Application.put_env(:sdr_agent, :prospect_search_test_key, "synthetic-key")

    on_exit(fn ->
      for {key, value} <- old do
        case value do
          {:ok, prior} -> Application.put_env(:sdr_agent, key, prior)
          :error -> Application.delete_env(:sdr_agent, key)
        end
      end
    end)

    :ok
  end

  defp context,
    do: %{
      id: "company-card",
      name: "Cedar Tools",
      domain: "cedar.test",
      website_url: "https://cedar.test"
    }

  defp execute(request) do
    assert Code.ensure_loaded?(@client), "missing Exa client contract"
    assert function_exported?(@client, :execute, 1), "missing ExaClient.execute/1"
    Function.capture(@client, :execute, 1).(request)
  end

  defp body(conn) do
    {:ok, encoded, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(encoded), conn}
  end

  test "company request pins category, auto, ten results and bounded text without deep synthesis" do
    Req.Test.stub(@transport, fn conn ->
      {payload, conn} = body(conn)
      assert conn.request_path == "/search"

      assert payload == %{
               "query" => "developer tools",
               "category" => "company",
               "type" => "auto",
               "numResults" => 10,
               "contents" => %{"text" => %{"maxCharacters" => 4000}}
             }

      Req.Test.json(conn, %{"results" => [], "costDollars" => %{"total" => 0.007}})
    end)

    assert {:ok, %{kind: :company, candidates: [], cost_dollars: 0.007}} =
             execute(%{kind: :company, query: "developer tools"})
  end

  test "people request includes only the confirmed company and explicit role query" do
    Req.Test.stub(@transport, fn conn ->
      {payload, conn} = body(conn)
      assert payload["category"] == "people"
      assert payload["numResults"] == 10
      assert payload["query"] =~ "Cedar Tools"
      assert payload["query"] =~ "Founder"
      refute Map.has_key?(payload, "excludeDomains")
      refute Map.has_key?(payload, "startPublishedDate")
      Req.Test.json(conn, %{"results" => []})
    end)

    assert {:ok, %{kind: :people}} =
             execute(%{kind: :people, query: "Founder", company: context()})
  end

  test "contents requests exactly one confirmed company URL and no enrichment or summary" do
    Req.Test.stub(@transport, fn conn ->
      {payload, conn} = body(conn)
      assert conn.request_path == "/contents"
      assert payload == %{"urls" => ["https://cedar.test"], "text" => %{"maxCharacters" => 4000}}

      Req.Test.json(conn, %{
        "results" => [%{"url" => "https://cedar.test/", "text" => "Literal website excerpt"}]
      })
    end)

    assert {:ok, %{kind: :contents, source: source}} =
             execute(%{kind: :contents, company: context()})

    assert source == %{
             url: "https://cedar.test",
             source_type: :company_site,
             retrieved_on: Date.utc_today(),
             excerpt: "Literal website excerpt"
           }
  end

  test "missing key and malformed request refuse before transport" do
    parent = self()

    Req.Test.stub(@transport, fn conn ->
      send(parent, :unexpected_egress)
      Req.Test.json(conn, %{})
    end)

    for key <- [nil, ""] do
      Application.put_env(:sdr_agent, :prospect_search_test_key, key)
      assert {:error, :unavailable} = execute(%{kind: :company, query: "developer tools"})
    end

    Application.put_env(:sdr_agent, :prospect_search_test_key, "synthetic-key")

    for request <- [
          nil,
          %{kind: :other},
          %{kind: :company, query: String.duplicate("x", 501)},
          %{kind: :people, query: "CEO"}
        ] do
      assert {:error, :invalid_input} = execute(request)
    end

    refute_received :unexpected_egress
  end

  test "closed provider failure is propagated without results or error body" do
    Req.Test.stub(@transport, &Plug.Conn.send_resp(&1, 402, "private-provider-body"))
    assert {:error, :quota_exceeded} = execute(%{kind: :company, query: "developer tools"})
  end
end
