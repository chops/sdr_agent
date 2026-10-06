defmodule WorkflowInstalledValidator do
  @schema_version 1
  @phoenix_required_artifacts ~w(agents-workflow-doctrine application-verify claude-rule-subagents downstream-validator downstream-validator-support project-dev-config project-test-config workflow-skills)
  @phoenix_required_paths ~w(.agents/skills .claude/rules/subagents.md .claude/skills .workflow/recipe.json .workflow/receipt.json AGENTS.md bin/verify bin/verify-workflow config/dev.exs config/test.exs)
  @docs_required_artifacts ~w(agents-workflow-doctrine application-verify-docs claude-rule-subagents downstream-validator downstream-validator-support template-envrc-docs template-flake-docs template-gitignore-docs template-project-facts-docs template-readme-docs workflow-skills-docs)
  @docs_required_paths ~w(.agents/skills .claude/rules/subagents.md .claude/skills .envrc .workflow/project-facts.md .workflow/recipe.json .workflow/receipt.json AGENTS.md README.org bin/verify bin/verify-workflow flake.nix notes/features/TEMPLATE.org notes/fixes/TEMPLATE.org)
  @mix_required_artifacts ~w(agents-workflow-doctrine application-verify claude-rule-subagents downstream-validator downstream-validator-support template-envrc-mix template-flake-mix template-gitignore-mix template-project-facts-mix workflow-skills-mix)
  @mix_required_paths ~w(.agents/skills .claude/rules/subagents.md .claude/skills .envrc .workflow/project-facts.md .workflow/recipe.json .workflow/receipt.json AGENTS.md bin/verify bin/verify-workflow flake.nix mix.exs notes/features/TEMPLATE.org notes/fixes/TEMPLATE.org)
  @forbidden_instruction_files ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"]
  @agents_limit 32 * 1024
  @workflow_begin "<!-- >>> workflow-factory:workflow-doctrine >>> -->"
  @workflow_end "<!-- <<< workflow-factory:workflow-doctrine <<< -->"
  @usage_begin "<!-- usage-rules-start -->"
  @usage_end "<!-- usage-rules-end -->"

  def main([root]) do
    case validate(Path.expand(root)) do
      :ok ->
        IO.puts("workflow receipt: ok")

      {:schema_error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)

      {:error, message} ->
        IO.puts(:stderr, "drifted from installed receipt: #{message}")
        System.halt(1)
    end
  end

  def main(_args) do
    IO.puts(:stderr, "usage: bin/verify-workflow")
    System.halt(2)
  end

  def validate(root) do
    with {:ok, receipt} <- decode_file(Path.join(root, ".workflow/receipt.json")),
         :ok <- validate_schema(receipt),
         :ok <- validate_receipt_shape(receipt),
         {:ok, project_kind} <- project_kind(root),
         :ok <- validate_required_artifacts(receipt, root, project_kind),
         :ok <- validate_recipe(receipt, root),
         :ok <- validate_units(receipt["owned_units"], root),
         :ok <- validate_agent_documents(root, project_kind),
         :ok <- validate_skill_projections(root) do
      :ok
    end
  end

  defp validate_schema(%{"schema_version" => @schema_version}), do: :ok

  defp validate_schema(%{"schema_version" => version}),
    do: {:schema_error, "unsupported installed receipt schema: #{inspect(version)}"}

  defp validate_schema(_receipt),
    do: {:schema_error, "installed receipt schema is missing"}

  defp validate_receipt_shape(receipt) when is_map(receipt) do
    required = ~w(schema_version identity selection owned_units validation)
    missing = required -- Map.keys(receipt)

    cond do
      missing != [] ->
        {:error, "receipt is missing fields: #{Enum.join(missing, ", ")}"}

      not is_map(receipt["identity"]) ->
        {:error, "receipt identity is invalid"}

      not is_map(receipt["selection"]) ->
        {:error, "receipt selection is invalid"}

      not is_list(receipt["owned_units"]) ->
        {:error, "receipt owned units are invalid"}

      not Enum.all?(receipt["owned_units"], &is_map/1) ->
        {:error, "receipt contains an invalid owned unit"}

      receipt["validation"] != %{"status" => "passed"} ->
        {:error, "receipt validation status is invalid"}

      true ->
        :ok
    end
  end

  defp project_kind(root) do
    with {:ok, recipe} <- decode_file(Path.join(root, ".workflow/recipe.json")) do
      case recipe["project_kind"] do
        nil -> {:ok, "phoenix"}
        kind when kind in ["phoenix", "mix", "docs"] -> {:ok, kind}
        _other -> {:error, "persisted recipe project kind is invalid"}
      end
    else
      _ -> {:error, "persisted recipe project kind is invalid"}
    end
  end

  defp validate_required_artifacts(receipt, root, project_kind) do
    selected = get_in(receipt, ["selection", "selected"])
    unit_ids = MapSet.new(receipt["owned_units"], & &1["artifact_id"])
    {required_artifacts, required_paths} = required_contract(project_kind)

    with true <- is_list(selected) || {:error, "receipt selected artifacts are invalid"},
         missing_selected = required_artifacts -- selected,
         true <-
           missing_selected == [] ||
             {:error, "missing required artifacts: #{Enum.join(missing_selected, ", ")}"},
         missing_units = Enum.reject(required_artifacts, &MapSet.member?(unit_ids, &1)),
         true <-
           missing_units == [] ||
             {:error, "missing required owned units: #{Enum.join(missing_units, ", ")}"} do
      Enum.reduce_while(required_paths, :ok, fn relative, :ok ->
        case File.lstat(Path.join(root, relative)) do
          {:ok, _stat} -> {:cont, :ok}
          _ -> {:halt, {:error, "required artifact is missing: #{relative}"}}
        end
      end)
    end
  end

  defp required_contract("phoenix"),
    do: {@phoenix_required_artifacts, @phoenix_required_paths}

  defp required_contract("docs"), do: {@docs_required_artifacts, @docs_required_paths}
  defp required_contract("mix"), do: {@mix_required_artifacts, @mix_required_paths}

  defp validate_recipe(receipt, root) do
    with expected when is_binary(expected) <- get_in(receipt, ["identity", "recipe_sha256"]),
         {:ok, body} <- File.read(Path.join(root, ".workflow/recipe.json")),
         true <- sha256(body) == expected || {:error, "persisted recipe digest differs"} do
      :ok
    else
      nil ->
        {:error, "receipt recipe identity is missing"}

      {:error, reason} when is_atom(reason) ->
        {:error, "persisted recipe is unavailable: #{format_reason(reason)}"}

      {:error, message} ->
        {:error, message}
    end
  end

  defp validate_units(units, root) do
    Enum.reduce_while(units, :ok, fn unit, :ok ->
      case validate_unit(unit, root) do
        :ok -> {:cont, :ok}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp validate_unit(unit, root) when is_map(unit) do
    with relative when is_binary(relative) <- unit["destination"],
         :ok <- validate_relative(relative),
         :ok <- reject_symlinked_ancestors(root, relative),
         {:ok, actual} <- unit_evidence(unit, Path.join(root, relative)),
         true <- actual == unit["sha256"] || {:error, "owned unit differs: #{unit["unit"]}"} do
      :ok
    else
      nil -> {:error, "owned unit destination is missing"}
      {:error, message} -> {:error, message}
      _ -> {:error, "owned unit destination is invalid"}
    end
  end

  defp validate_unit(_unit, _root), do: {:error, "receipt contains an invalid owned unit"}

  defp unit_evidence(%{"symlink_target" => expected}, path) do
    case File.read_link(path) do
      {:ok, ^expected} ->
        if(File.exists?(path),
          do: {:ok, sha256(expected)},
          else: {:error, "owned symlink is dangling"}
        )

      {:ok, _other} ->
        {:error, "owned symlink target differs"}

      {:error, reason} ->
        {:error, "owned symlink is unavailable: #{format_reason(reason)}"}
    end
  end

  defp unit_evidence(%{"marker_id" => marker_id}, path) do
    with {:ok, body} <- File.read(path),
         {:ok, region} <- managed_region(body, marker_id, path) do
      {:ok, sha256(region)}
    end
  end

  defp unit_evidence(%{"structured_entries" => entries, "structured_entry_ids" => ids}, path) do
    with true <- Enum.sort(Map.keys(entries)) == ids || {:error, "structured entry IDs differ"},
         {:ok, document} <- decode_file(path),
         {:ok, actual} <- extract_structured(document, entries) do
      {:ok, canonical_sha256(actual)}
    end
  end

  defp unit_evidence(%{"structured_entries" => _entries}, _path),
    do: {:error, "structured entry IDs are missing"}

  defp unit_evidence(%{"elixir_project_config" => expected}, path) do
    with {:ok, body} <- File.read(path),
         {:ok, actual} <- extract_mix_project_config(body, expected) do
      {:ok, canonical_sha256(actual)}
    end
  end

  defp unit_evidence(%{"owned_lines" => lines}, path) do
    with {:ok, body} <- File.read(path),
         true <-
           Enum.all?(lines, &(&1 in String.split(body, "\n", trim: true))) ||
             {:error, "owned lines differ"} do
      {:ok, canonical_sha256(lines)}
    end
  end

  defp unit_evidence(%{"owned_tree_entries" => entries}, path) do
    with {:ok, actual} <- owned_tree_entries(path, entries) do
      {:ok, canonical_sha256(actual)}
    end
  end

  defp unit_evidence(%{"lifecycle" => "external_generator", "sha256" => digest}, _path),
    do: {:ok, digest}

  defp unit_evidence(_unit, path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        with({:ok, body} <- File.read(path), do: {:ok, sha256(body)})

      {:ok, %File.Stat{type: :directory}} ->
        tree_digest(path)

      _ ->
        {:error, "owned destination is unavailable"}
    end
  end

  defp validate_agent_documents(root, project_kind) do
    with {:ok, agents} <- File.read(Path.join(root, "AGENTS.md")),
         {:ok, workflow} <- marker_range(agents, @workflow_begin, @workflow_end, "workflow"),
         {:ok, usage} <- marker_range(agents, @usage_begin, @usage_end, "usage-rules"),
         true <- workflow != nil || {:error, "workflow markers are missing"},
         :ok <- validate_usage_region(workflow, usage, project_kind),
         true <- byte_size(agents) <= @agents_limit || {:error, "combined AGENTS exceeds 32 KiB"},
         :ok <- reject_instruction_files(root) do
      :ok
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "agent document is unavailable: #{format_reason(reason)}"}

      {:error, message} ->
        {:error, message}
    end
  end

  defp reject_instruction_files(root) do
    case Enum.find(@forbidden_instruction_files, &present?(Path.join(root, &1))) do
      nil ->
        :ok

      relative ->
        {:error,
         "forbidden Claude instruction file present: #{relative} " <>
           "(it disables native AGENTS.md loading; see ADR-0011)"}
    end
  end

  defp present?(path) do
    case File.lstat(path) do
      {:error, reason} when reason in [:enoent, :enotdir] -> false
      _present_or_uninspectable -> true
    end
  end

  defp validate_usage_region(_workflow, nil, project_kind) when project_kind in ["docs", "mix"],
    do: :ok

  defp validate_usage_region({_, workflow_end}, {usage_start, _}, _project_kind)
       when workflow_end < usage_start,
       do: :ok

  defp validate_usage_region(_workflow, nil, _project_kind),
    do: {:error, "usage-rules markers are missing"}

  defp validate_usage_region(_workflow, _usage, _project_kind),
    do: {:error, "workflow and usage-rules marker regions overlap or are reversed"}

  defp validate_skill_projections(root) do
    physical_root = Path.join(root, ".claude/skills")
    links_root = Path.join(root, ".agents/skills")

    with {:ok, physical} <- list_entries(physical_root, :directory),
         {:ok, links} <- list_entries(links_root, :symlink),
         true <-
           physical == links || {:error, "skill projection set differs from physical skills"} do
      Enum.reduce_while(physical, :ok, fn name, :ok ->
        skill = Path.join([physical_root, name, "SKILL.md"])
        link = Path.join(links_root, name)
        expected = "../../.claude/skills/#{name}"

        with true <-
               Regex.match?(~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/, name) ||
                 {:error, "invalid skill name: #{name}"},
             {:ok, body} <- File.read(skill),
             [declared] <-
               Regex.run(~r/\A---\r?\n.*?^name:\s*([^\s]+)\s*$.*?^---\s*$/ms, body,
                 capture: :all_but_first
               ),
             true <-
               String.trim(declared, "\"'") == name ||
                 {:error, "skill name differs from directory: #{name}"},
             {:ok, ^expected} <- File.read_link(link),
             true <- File.exists?(link) || {:error, "skill projection is dangling: #{name}"} do
          {:cont, :ok}
        else
          {:error, message} when is_binary(message) -> {:halt, {:error, message}}
          _ -> {:halt, {:error, "invalid skill projection: #{name}"}}
        end
      end)
    end
  end

  defp marker_range(body, begin_marker, end_marker, label) do
    begins = positions(body, begin_marker)
    ends = positions(body, end_marker)

    case {begins, ends} do
      {[], []} -> {:ok, nil}
      {[start], [stop]} when start < stop -> {:ok, {start, stop + byte_size(end_marker)}}
      _ -> {:error, "#{label} markers must appear exactly once, balanced, and in order"}
    end
  end

  defp positions(body, marker), do: positions(body, marker, 0, [])

  defp positions(body, marker, offset, found) do
    case :binary.match(body, marker, scope: {offset, byte_size(body) - offset}) do
      {position, _length} ->
        positions(body, marker, position + byte_size(marker), found ++ [position])

      :nomatch ->
        found
    end
  end

  defp managed_region(body, marker_id, path) do
    begin_marker = "<!-- >>> workflow-factory:#{marker_id} >>> -->"
    end_marker = "<!-- <<< workflow-factory:#{marker_id} <<< -->"

    {begin_marker, end_marker} =
      if Path.extname(path) == ".exs",
        do: {"# " <> begin_marker, "# " <> end_marker},
        else: {begin_marker, end_marker}

    with 1 <- count(body, begin_marker),
         1 <- count(body, end_marker),
         [_prefix, rest] <- String.split(body, begin_marker, parts: 2),
         [content, _suffix] <- String.split(rest, end_marker, parts: 2) do
      {:ok, begin_marker <> content <> end_marker <> "\n"}
    else
      _ -> {:error, "managed marker region differs: #{marker_id}"}
    end
  end

  defp extract_structured(document, entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {id, entry}, {:ok, actual} ->
      case structured_value(document, entry) do
        {:ok, value} -> {:cont, {:ok, Map.put(actual, id, Map.put(entry, "value", value))}}
        error -> {:halt, error}
      end
    end)
  end

  defp structured_value(document, %{"pointer" => "/enabledPlugins/" <> encoded}) do
    key = decode_pointer(encoded)

    case get_in(document, ["enabledPlugins", key]) do
      nil -> {:error, "structured plugin entry is missing"}
      value -> {:ok, value}
    end
  end

  defp structured_value(document, %{"pointer" => "/hooks/PreToolUse/" <> _, "value" => expected}) do
    matcher = expected["matcher"]

    case Enum.find(get_in(document, ["hooks", "PreToolUse"]) || [], &(&1["matcher"] == matcher)) do
      nil -> {:error, "structured hook entry is missing"}
      value -> {:ok, value}
    end
  end

  defp structured_value(_document, _entry), do: {:error, "unsupported structured entry"}
  defp decode_pointer(value), do: value |> String.replace("~1", "/") |> String.replace("~0", "~")

  defp extract_mix_project_config(
         body,
         %{"function" => expected_function, "project_entry" => "usage_rules: usage_rules()"} =
           evidence
       ) do
    with {:ok, {:defmodule, _, [_name, [do: module_body]]}} <- Code.string_to_quoted(body),
         expressions =
           (case module_body do
              {:__block__, _, values} -> values
              value -> [value]
            end),
         [project] <- Enum.filter(expressions, &definition?(&1, :def, :project)),
         {:def, _, [{:project, _, nil}, [do: keyword]]} <- project,
         [entry] <- Keyword.get_values(keyword, :usage_rules),
         true <- Macro.to_string(entry) == "usage_rules()",
         [function] <- Enum.filter(expressions, &definition?(&1, :defp, :usage_rules)),
         true <- Macro.to_string(function) == expected_function do
      {:ok, evidence}
    else
      _ -> {:error, "owned usage_rules project config differs"}
    end
  end

  defp extract_mix_project_config(_body, _evidence),
    do: {:error, "invalid usage_rules project config evidence"}

  defp definition?({kind, _, [{name, _, nil}, _]}, kind, name), do: true
  defp definition?(_value, _kind, _name), do: false

  defp owned_tree_entries(root, expected) do
    Enum.reduce_while(expected, {:ok, []}, fn entry, {:ok, actual} ->
      path = Path.join(root, entry["path"])

      result =
        case {entry["type"], File.lstat(path)} do
          {"directory", {:ok, %File.Stat{type: :directory}}} ->
            {:ok, entry}

          {"file", {:ok, %File.Stat{type: :regular}}} ->
            with(
              {:ok, body} <- File.read(path),
              do: {:ok, Map.put(entry, "sha256", sha256(body))}
            )

          _ ->
            {:error, "owned tree entry differs: #{entry["path"]}"}
        end

      case result do
        {:ok, value} -> {:cont, {:ok, actual ++ [value]}}
        error -> {:halt, error}
      end
    end)
  end

  defp tree_digest(root) do
    with {:ok, entries} <- tree_entries(root, root), do: {:ok, canonical_sha256(entries)}
  end

  defp tree_entries(path, root) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        relative = Path.relative_to(path, root)
        prefix = if relative == ".", do: [], else: [%{"path" => relative, "type" => "directory"}]

        with {:ok, children} <- File.ls(path) do
          Enum.reduce_while(Enum.sort(children), {:ok, prefix}, fn child, {:ok, entries} ->
            case tree_entries(Path.join(path, child), root) do
              {:ok, values} -> {:cont, {:ok, entries ++ values}}
              error -> {:halt, error}
            end
          end)
        end

      {:ok, %File.Stat{type: :regular}} ->
        with(
          {:ok, body} <- File.read(path),
          do:
            {:ok,
             [
               %{
                 "path" => Path.relative_to(path, root),
                 "sha256" => sha256(body),
                 "type" => "file"
               }
             ]}
        )

      _ ->
        {:error, "owned tree contains an unsupported entry"}
    end
  end

  defp list_entries(root, expected_type) do
    with {:ok, entries} <- File.ls(root) do
      entries
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn name, {:ok, names} ->
        case File.lstat(Path.join(root, name)) do
          {:ok, %File.Stat{type: ^expected_type}} ->
            {:cont, {:ok, names ++ [name]}}

          _ ->
            {:halt, {:error, "invalid skill tree entry: #{name}"}}
        end
      end)
    else
      {:error, reason} -> {:error, "skill tree is unavailable: #{format_reason(reason)}"}
    end
  end

  defp validate_relative(path) do
    cond do
      Path.type(path) != :relative ->
        {:error, "owned destination is absolute"}

      path in ["", "."] ->
        {:error, "owned destination is empty"}

      Enum.any?(Path.split(path), &(&1 == "..")) ->
        {:error, "owned destination escapes project root"}

      true ->
        :ok
    end
  end

  defp reject_symlinked_ancestors(root, relative) do
    relative
    |> Path.dirname()
    |> Path.split()
    |> Enum.reduce_while({:ok, root}, fn segment, {:ok, parent} ->
      path = Path.join(parent, segment)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, "owned destination has a symlinked ancestor"}}

        {:ok, %File.Stat{type: :directory}} ->
          {:cont, {:ok, path}}

        {:error, :enoent} ->
          {:cont, {:ok, path}}

        _ ->
          {:halt, {:error, "owned destination ancestor is invalid"}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp decode_file(path) do
    with {:ok, body} <- File.read(path) do
      try do
        case :json.decode(body, :ok, %{
               object_start: fn _ -> %{} end,
               object_push: &json_push/3,
               object_finish: fn acc, old -> {acc, old} end
             }) do
          {value, :ok, rest} when is_binary(rest) ->
            if(String.trim(rest) == "",
              do: {:ok, value},
              else: {:error, "JSON has trailing content"}
            )
        end
      rescue
        error -> {:error, "invalid JSON: #{Exception.message(error)}"}
      end
    else
      {:error, reason} -> {:error, "cannot read #{Path.basename(path)}: #{format_reason(reason)}"}
    end
  end

  defp json_push(key, value, acc) do
    if Map.has_key?(acc, key),
      do: raise(ArgumentError, "duplicate JSON object key: #{key}"),
      else: Map.put(acc, key, value)
  end

  defp canonical_sha256(value), do: sha256(canonical(value) <> "\n")

  defp canonical(value) when is_map(value),
    do:
      "{" <>
        (value
         |> Enum.sort_by(&elem(&1, 0))
         |> Enum.map_join(",", fn {key, child} -> scalar(key) <> ":" <> canonical(child) end)) <>
        "}"

  defp canonical(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical/1) <> "]"

  defp canonical(value) when is_binary(value), do: scalar(value)
  defp canonical(value) when is_number(value) or is_boolean(value), do: scalar(value)
  defp canonical(nil), do: "null"
  defp canonical(:null), do: "null"
  defp scalar(value), do: value |> :json.encode() |> IO.iodata_to_binary()

  defp count(body, value), do: length(String.split(body, value)) - 1
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp format_reason(reason), do: :file.format_error(reason) |> List.to_string()
end

WorkflowInstalledValidator.main(System.argv())
