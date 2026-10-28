# DRAFT r2 (outside the repository; review only). The PURE scope only:
# parsers, the paths shape, the reason family, the pinned facts and the
# build partition. The filesystem and command cases are a separately scoped
# external file (interface r2 section 6), not here.
defmodule SdrAgent.Prototype.ClusterTest do
  @moduledoc """
  IF-7 cluster marker read API, pure scope (S4 interface r2).

  RED (deny-only declarations): every test fails at its first assertion,
  because each function returns `{:error, :not_implemented}`. Failure texts
  are fixed; no captured bytes are printed.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Prototype.Cluster

  @reasons [
    :uid_unknown,
    :marker_missing,
    :marker_not_owned,
    :marker_invalid,
    :marker_mismatch,
    :data_dir_not_owned,
    :binary_mismatch,
    :control_unreadable,
    :control_mismatch,
    :socket_dir_not_owned,
    :cluster_check_failed
  ]
  @root "/Users/charles/.local/state/sdr-agent/prototype/d237"
  @pg_bin "/nix/store/zndqgdxn4p28iyax8raza3pfn7lkjw64-postgresql-18.6/bin"
  @good ~s({"system_identifier":"7400000000000000001","data_dir":"#{@root}/pgdata",) <>
          ~s("socket_dir":"/private/tmp/d237-pg","port":5541,"binary":"#{@pg_bin}"}\n)

  test "the reason family is exactly the reviewed 11, in step order" do
    assert Cluster.reasons() == @reasons, "the reason family is not the reviewed list"
  end

  test "the pinned facts equal bin/prototype-pg's constants" do
    assert Cluster.pinned() == %{
             root: @root,
             socket_dir: "/private/tmp/d237-pg",
             port: 5541,
             pg_bin: @pg_bin
           },
           "the pinned facts differ from the script"
  end

  test "parse_marker: the exact template gives the field texts" do
    assert Cluster.parse_marker(@good) ==
             {:ok,
              %{
                system_identifier: "7400000000000000001",
                data_dir: @root <> "/pgdata",
                socket_dir: "/private/tmp/d237-pg",
                port: "5541",
                binary: @pg_bin
              }},
           "the exact template was not parsed to its field texts"
  end

  test "parse_marker: every deviation is marker_invalid" do
    bad = [
      "",
      String.trim_trailing(@good, "\n"),
      @good <> "\n",
      @good <> @good,
      String.replace(@good, "\n", "\r\n"),
      String.replace(@good, ~s("port":5541), ~s("port": 5541)),
      String.replace(@good, ~s("port":5541), ~s("port":"5541")),
      String.replace(@good, "7400000000000000001", ""),
      String.replace(@good, "7400000000000000001", "123456789012345678901"),
      String.replace(@good, "7400000000000000001", "74000000000000000O1"),
      String.replace(@good, "7400000000000000001", "٧٤"),
      String.replace(@good, ~s("binary"), ~s("bin")),
      String.replace(@good, ~s(}\n), ~s(,"extra":"x"}\n)),
      String.replace(@good, "/pgdata", "/pg\\data"),
      String.replace(@good, "/pgdata", "/pg\tdata"),
      String.replace(@good, "/pgdata", "/pgdata" <> String.duplicate("a", 1100)),
      String.duplicate("a", 4097),
      <<0xFF>> <> @good
    ]

    for {bytes, index} <- Enum.with_index(bad) do
      assert Cluster.parse_marker(bytes) == {:error, :marker_invalid},
             "bad marker #{index} was not marker_invalid"
    end
  end

  test "parse_marker keeps leading zeros as text (compared as text later)" do
    zeros = String.replace(@good, "7400000000000000001", "07400000000000000001")

    assert match?(
             {:ok, %{system_identifier: "07400000000000000001"}},
             Cluster.parse_marker(zeros)
           ),
           "a leading-zero identifier was normalized or refused by the parser"
  end

  test "parse_control: exactly one identifier line among the output" do
    out =
      "pg_control version number:            1800\nDatabase system identifier:           7400000000000000001\nCatalog version number:               202510101\n"

    assert Cluster.parse_control(out) == {:ok, "7400000000000000001"},
           "the identifier line was not read"

    for {bad, index} <-
          Enum.with_index([
            "",
            "Database system identifier:\n",
            "Database system identifier: 12x\n",
            "Database system identifier:  1\nDatabase system identifier:  1\n",
            "Datenbanksystemidentifikation:  1\n",
            String.duplicate("x", 65_537)
          ]) do
      assert Cluster.parse_control(bad) == {:error, :control_unreadable},
             "bad control output #{index} was not control_unreadable"
    end
  end

  test "parse_uid: digits and one newline only" do
    assert Cluster.parse_uid("501\n") == {:ok, 501}, "a normal id -u output was refused"

    for {bad, index} <-
          Enum.with_index(["", "501", "501\n\n", " 501\n", "50a\n", "12345678901\n"]) do
      assert Cluster.parse_uid(bad) == {:error, :uid_unknown},
             "bad uid output #{index} was accepted"
    end
  end

  test "paths_ok?: exact keys, absolute canonical paths, integer port" do
    good = %{root: @root, socket_dir: "/private/tmp/d237-pg", port: 5541, pg_bin: @pg_bin}
    assert Cluster.paths_ok?(good) == true, "the pinned paths shape was refused"

    for {bad, index} <-
          Enum.with_index([
            Map.delete(good, :port),
            Map.put(good, :extra, 1),
            %{good | root: "relative/d237"},
            %{good | root: @root <> "/"},
            %{good | root: "/Users/charles/../charles/d237"},
            %{good | root: "/Users/charles//d237"},
            %{good | port: "5541"},
            %{good | port: 0},
            %{good | port: 65_536},
            %{good | pg_bin: :bin},
            Map.to_list(good),
            nil
          ]) do
      assert Cluster.paths_ok?(bad) == false, "bad paths #{index} were accepted"
    end
  end

  test "check/1 refuses a malformed paths map before any I/O" do
    assert Cluster.check(%{root: "relative"}) == {:error, :cluster_check_failed},
           "a malformed paths map was not cluster_check_failed"
  end
end
