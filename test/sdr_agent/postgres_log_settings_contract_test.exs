defmodule SdrAgent.PostgresLogSettingsContractTest do
  @moduledoc """
  5b (D-178; #156 sections 3.2 and 3.3), DB-free: the single settings source
  `priv/postgres/log_settings.json` holds exactly the approved baseline
  (`SdrAgent.Test.PostgresLogContract`, pinned independently), the CI
  renderer `.github/scripts/render-pg-log-settings.sh` turns it into exactly
  the pinned `postgresql.conf` lines in devenv's spelling, and it refuses any
  out-of-contract input with no output. The wiring checks pin that
  `devenv.nix` reads the same file through `builtins.fromJSON` and that
  `hermetic-verify.sh` appends the renderer's output before starting its
  throwaway cluster. The actual devenv-generated file is checked by
  `test/postgres_log_settings/devenv-render-test.sh` (it needs a Nix build).
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Test.PostgresLogContract, as: Contract

  @json "priv/postgres/log_settings.json"
  @renderer ".github/scripts/render-pg-log-settings.sh"

  defp render(path) do
    System.cmd("bash", [@renderer, path], stderr_to_stdout: false, env: [{"LC_ALL", "C"}])
  end

  defp write_fixture!(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp approved_json, do: Jason.encode!(Contract.json_map())

  describe "the canonical settings file" do
    test "decodes to exactly the approved baseline: keys, JSON types and values" do
      assert File.regular?(@json), "5b: #{@json} must exist"
      assert {:ok, decoded} = Jason.decode(File.read!(@json))
      # `===` and the per-key types: `==` would accept 0.0 for 0.
      assert decoded === Contract.json_map()

      for name <- Contract.names() do
        value = Map.fetch!(decoded, name)

        ok? =
          case Contract.json_type(name) do
            :boolean -> is_boolean(value)
            :string -> is_binary(value)
            :integer -> is_integer(value)
            :number -> is_number(value)
          end

        assert ok?,
               "5b: #{name} must be a JSON #{Contract.json_type(name)}, got #{inspect(value)}"
      end
    end
  end

  describe "the CI renderer" do
    test "renders exactly the pinned lines, sorted, in devenv's spelling" do
      assert File.regular?(@renderer), "5b: #{@renderer} must exist"
      assert {out, 0} = render(@json)
      assert out == Contract.rendered_text()
    end

    @tag :tmp_dir
    test "doubles a single quote inside a string value", %{tmp_dir: dir} do
      assert File.regular?(@renderer), "5b: #{@renderer} must exist"
      map = Map.put(Contract.json_map(), "log_filename", "a'b.log")
      path = write_fixture!(dir, "quote.json", Jason.encode!(map))
      assert {out, 0} = render(path)
      assert out =~ "\nlog_filename = 'a''b.log'\n"
    end

    @tag :tmp_dir
    test "refuses out-of-contract input with a nonzero exit and no output", %{tmp_dir: dir} do
      assert File.regular?(@renderer), "5b: #{@renderer} must exist"
      base = Contract.json_map()

      cases = [
        unknown_key: Jason.encode!(Map.put(base, "log_connections", true)),
        missing_key: Jason.encode!(Map.delete(base, "log_statement")),
        bool_as_string: Jason.encode!(Map.put(base, "logging_collector", "on")),
        string_as_number: Jason.encode!(Map.put(base, "log_rotation_age", 1440)),
        number_as_string: Jason.encode!(Map.put(base, "log_parameter_max_length", "0")),
        integer_as_float: Jason.encode!(Map.put(base, "log_parameter_max_length", 0.0)),
        bool_as_integer: Jason.encode!(Map.put(base, "log_duration", 0)),
        newline_value: Jason.encode!(Map.put(base, "log_directory", "log\nport = 1")),
        control_value: Jason.encode!(Map.put(base, "log_directory", "log\u0001")),
        backslash_value: Jason.encode!(Map.put(base, "log_directory", "log\\x")),
        non_object: Jason.encode!([base]),
        malformed: "{\"log_statement\": ",
        empty: ""
      ]

      for {label, content} <- cases do
        path = write_fixture!(dir, "#{label}.json", content)
        assert {out, status} = render(path)
        assert status != 0, "5b: #{label} must be refused"
        assert out == "", "5b: #{label} must produce no output, got #{inspect(out)}"
      end

      assert {"", status} = render(Path.join(dir, "absent.json"))
      assert status != 0, "5b: a missing file must be refused"
    end

    # Codex 5b GREEN review G1: jq reads a stream of JSON values, so the file
    # must hold exactly one document, and a bad later document must not leave
    # the earlier one's lines on stdout.
    @tag :tmp_dir
    test "refuses a file holding more than one JSON document, with no output", %{tmp_dir: dir} do
      assert File.regular?(@renderer), "5b: #{@renderer} must exist"
      one = approved_json()

      cases = [
        two_objects: one <> one,
        two_objects_spaced: one <> "\n\n" <> one,
        object_then_malformed: one <> "{\"log_statement\": ",
        object_then_scalar: one <> "1",
        object_then_null: one <> "null"
      ]

      for {label, content} <- cases do
        path = write_fixture!(dir, "#{label}.json", content)
        assert {out, status} = render(path)
        assert status != 0, "5b: #{label} must be refused"
        assert out == "", "5b: #{label} must produce no output, got #{inspect(out)}"
      end
    end

    @tag :tmp_dir
    test "is pure: the approved file and its copy render identically", %{tmp_dir: dir} do
      assert File.regular?(@renderer), "5b: #{@renderer} must exist"
      path = write_fixture!(dir, "copy.json", approved_json())
      assert {out, 0} = render(path)
      assert out == Contract.rendered_text()
    end
  end

  describe "the devenv render check's pinned expectation" do
    test "expected-contract.conf is exactly the contract's rendered lines" do
      assert File.read!("test/postgres_log_settings/expected-contract.conf") ==
               Contract.rendered_text()
    end
  end

  describe "wiring" do
    test "devenv.nix reads the settings through builtins.fromJSON of the same file" do
      source = File.read!("devenv.nix")

      assert source =~
               ~r/services\.postgres\.settings\s*=\s*builtins\.fromJSON\s*\(\s*builtins\.readFile\s+\.\/priv\/postgres\/log_settings\.json\s*\)/,
             "5b: devenv.nix must set services.postgres.settings from #{@json}"
    end

    test "hermetic-verify.sh appends the rendered settings before pg_ctl start" do
      source = File.read!(".github/scripts/hermetic-verify.sh")

      render_at =
        :binary.match(source, "render-pg-log-settings.sh priv/postgres/log_settings.json")

      start_at = :binary.match(source, "pg_ctl -D \"$PGDATA\" -l")

      assert render_at != :nomatch,
             "5b: hermetic-verify.sh must render #{@json} into the throwaway cluster"

      assert {r, _} = render_at
      assert {s, _} = start_at
      assert r < s, "5b: the settings must be appended before the cluster starts"

      assert source =~
               ~r/render-pg-log-settings\.sh priv\/postgres\/log_settings\.json >> "\$PGDATA\/postgresql\.conf"/
    end

    test "CI runs the devenv render check as its own required step, online, before the hermetic gate" do
      ci = File.read!(".github/workflows/ci.yml")
      render_at = :binary.match(ci, "bash test/postgres_log_settings/devenv-render-test.sh")
      hermetic_at = :binary.match(ci, "bash .github/scripts/hermetic-verify.sh")

      assert render_at != :nomatch,
             "5b: ci.yml must run test/postgres_log_settings/devenv-render-test.sh"

      assert {r, _} = render_at
      assert {h, _} = hermetic_at
      assert r < h
    end

    test "the CI cluster's port and network isolation are unchanged" do
      source = File.read!(".github/scripts/hermetic-verify.sh")
      assert source =~ ~s(-o "-h 127.0.0.1 -p 5520 -k $work" start)
      assert source =~ "network is NOT blocked"
    end
  end
end
