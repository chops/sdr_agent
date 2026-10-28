defmodule SdrAgent.Prototype.SeedDir do
  @moduledoc """
  The bounded reader of the D-237 GTM seed directory (interfaces r6 IF-7):
  one directory, mode 0700, holding exactly the four plain JSON files
  `offering_profile.json`, `writing_guide.json`, `campaign.json` and
  `provenance.json`, each a regular 0600 file of at most 64 KiB whose full
  sha256 equals its argument. It never evaluates its input and never
  touches the network.

  **Reading (Codex R4).** After the lstat precheck of the root and the four
  files, each file is read through ONE handle, as `SpotcheckManifest.artifact/2`
  reads an artifact: the root must still be the checked directory and still
  0700 (`{"seed_dir", :changed | :dir_mode}`); the file by `lstat` must be a
  regular 0600 file of at most 64 KiB (`:not_regular`, `:file_mode`,
  `:too_large`); the opened object itself (fstat on the handle) must be that
  same file, still 0600 and within the bound (`:changed`), with the root
  rechecked again before any byte is read; the read stops at the bound plus
  one sentinel byte (`:too_large`); the handle is closed on every path; the
  full sha256 of those bytes must equal the argument (`:digest_mismatch`).
  The bytes are then decoded by `SdrAgent.Prototype.BoundedJson.decode/2`.
  Nothing is chmod-ed or repaired. Known limitation (availability only): a
  FIFO substituted after the precheck can block the open.

  `read/2` checks:
  - the exact key sets of IF-7 (no class field; a provenance key inside the
    profile is an unknown key) and each file's depth bound (profile 3, guide
    1, campaign 4, provenance 5);
  - `provenance.json`: its `files` digests equal the three content files;
    every ref of `{profile.name, profile.summary, profile.audience, guide,
    campaign.icp, campaign.step} ∪ {item:<id>}` exactly once; each ref's
    class derived from the ref (claim, instruction, targeting); a claim ref
    is `public: true`; `public: true` means at least one source and every
    source `public_url`;
  - `campaign.json`: the criteria bounds (industries and geographies 1..5,
    personas and triggers 1..8, each string 1..400 characters, integer
    counts at least 0, max at least min), exactly one step object, and
    `sender_name` exactly `sender_name/0`;
  - the guide text contains `sender_name/0` byte for byte.

  Settings text (the profile, item and guide text, the step instructions) is
  type-checked only: the settings content rules check it inside the seed
  actions, and nothing is normalized before that check.

  It returns `{:ok, %{offering_profile:, writing_guide:, campaign:,
  provenance:, provenance_bytes:, sha256: %{…}}}`. A refusal is
  `{:error, {location, rule}}`: `seed_dir`, a file name, or
  `<file>:<schema path>`; value-free.
  """

  import Bitwise

  alias SdrAgent.Prototype.BoundedJson
  alias SdrAgent.Prototype.DossierParser.Rules

  @sender_name "the GTMscape team"
  @files ["offering_profile.json", "writing_guide.json", "campaign.json", "provenance.json"]
  @keys %{
    "offering_profile.json" => :offering_profile,
    "writing_guide.json" => :writing_guide,
    "campaign.json" => :campaign,
    "provenance.json" => :provenance
  }
  @depth %{
    "offering_profile.json" => 3,
    "writing_guide.json" => 1,
    "campaign.json" => 4,
    "provenance.json" => 5
  }
  @max_bytes 65_536
  @known_keys ~w(name summary audience items id kind text icp description criteria employee_count_min employee_count_max industries geographies personas triggers sequence step instructions sender_name schema schema_version files offering_profile writing_guide campaign entries ref public sources retrieved_on)
  @item_kinds ~w(feature use_case outcome limit proof_point)
  @claim_kinds ~w(feature use_case outcome proof_point)
  @provenance_schema "sdr-agent.prototype-seed-provenance"
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)
  @repo_ref ~r/\A[0-9a-f]{40}:[A-Za-z0-9._\/-]{1,200}\z/
  @content_files [
    {"offering_profile", :offering_profile},
    {"writing_guide", :writing_guide},
    {"campaign", :campaign}
  ]
  @criteria_lists [{"industries", 5}, {"geographies", 5}, {"personas", 8}, {"triggers", 8}]

  @doc "The 17-byte sender name constant, compared byte for byte."
  @spec sender_name() :: String.t()
  def sender_name, do: @sender_name

  @doc "The four seed file names."
  @spec files() :: [String.t()]
  def files, do: @files

  @doc """
  Reads the seed directory `dir` against the four digests
  `%{offering_profile:, writing_guide:, campaign:, provenance:}`.
  """
  @spec read(Path.t(), map()) :: {:ok, map()} | {:error, {String.t(), atom()}}
  def read(dir, sha256s) when is_binary(dir) and is_map(sha256s) do
    with :ok <- digests(sha256s),
         {:ok, root} <- directory(dir),
         :ok <- entries(dir),
         :ok <- modes(dir),
         :ok <- seam(:after_precheck, dir),
         {:ok, bins} <- read_all(dir, root, sha256s),
         {:ok, docs} <- decode_all(bins),
         :ok <- profile(docs[:offering_profile]),
         :ok <- guide(docs[:writing_guide]),
         :ok <- campaign(docs[:campaign]),
         :ok <- sender_in_guide(docs[:writing_guide]),
         :ok <- provenance(docs[:provenance], docs[:offering_profile], sha256s) do
      {:ok,
       %{
         offering_profile: docs[:offering_profile],
         writing_guide: docs[:writing_guide],
         campaign: docs[:campaign],
         provenance: docs[:provenance],
         provenance_bytes: bins[:provenance],
         sha256: Map.take(sha256s, Map.values(@keys))
       }}
    end
  end

  ## The directory and its files

  defp digests(sha256s) do
    if Enum.all?(
         Map.values(@keys),
         &(is_binary(sha256s[&1]) and Regex.match?(@hex64, sha256s[&1]))
       ),
       do: :ok,
       else: {:error, {"seed_sha256", :format}}
  end

  defp directory(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory, mode: mode} = root} when (mode &&& 0o777) == 0o700 ->
        {:ok, root}

      _other ->
        {:error, {"seed_dir", :dir_mode}}
    end
  end

  defp entries(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        cond do
          Enum.any?(names, &(&1 not in @files)) ->
            {:error, {"seed_dir", :unknown_entry}}

          missing = Enum.find(Enum.sort(@files), &(&1 not in names)) ->
            {:error, {missing, :missing_file}}

          true ->
            :ok
        end

      {:error, _} ->
        {:error, {"seed_dir", :dir_mode}}
    end
  end

  defp modes(dir) do
    Enum.find_value(Enum.sort(@files), :ok, fn name ->
      case File.lstat(Path.join(dir, name)) do
        {:ok, %File.Stat{type: :regular, mode: mode}} when (mode &&& 0o777) == 0o600 -> nil
        {:ok, %File.Stat{type: :regular}} -> {:error, {name, :file_mode}}
        _other -> {:error, {name, :not_regular}}
      end
    end)
  end

  defp read_all(dir, root, sha256s) do
    Enum.reduce_while(Enum.sort(@files), {:ok, %{}}, fn name, {:ok, acc} ->
      key = @keys[name]

      case read_one(dir, root, name, sha256s[key]) do
        {:ok, bin} -> {:cont, {:ok, Map.put(acc, key, bin)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # One file through ONE handle (see the moduledoc, "Reading").
  defp read_one(dir, root, name, sha256) do
    path = Path.join(dir, name)

    with :ok <- same_root(dir, root),
         {:ok, checked} <- private_file(path, name),
         {:ok, bytes} <- read_checked(dir, root, path, name, checked) do
      if hex(:crypto.hash(:sha256, bytes)) == sha256,
        do: {:ok, bytes},
        else: {:error, {name, :digest_mismatch}}
    end
  end

  # The root is still the checked directory, and still 0700.
  defp same_root(dir, root) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory} = now} ->
        cond do
          not same_object?(now, root) -> {:error, {"seed_dir", :changed}}
          (now.mode &&& 0o777) != 0o700 -> {:error, {"seed_dir", :dir_mode}}
          true -> :ok
        end

      _other ->
        {:error, {"seed_dir", :changed}}
    end
  end

  # By lstat: a regular 0600 file within the bound.
  defp private_file(path, name) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular} = stat} -> private_stat(stat, name)
      {:ok, _other} -> {:error, {name, :not_regular}}
      {:error, _reason} -> {:error, {name, :unreadable}}
    end
  end

  defp private_stat(stat, name) do
    cond do
      (stat.mode &&& 0o777) != 0o600 -> {:error, {name, :file_mode}}
      stat.size > @max_bytes -> {:error, {name, :too_large}}
      true -> {:ok, stat}
    end
  end

  # Before any content is read, the opened object itself (fstat on the
  # handle) must be the checked file, still private and within the bound,
  # and the root must still be the checked 0700 directory. The read stops
  # at the bound plus one sentinel byte. The handle is closed on every path.
  defp read_checked(dir, root, path, name, checked) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, handle} ->
        try do
          with :ok <- opened_object(handle, name, checked),
               :ok <- same_root(dir, root),
               :ok <- seam(:after_open, {name, handle}),
               {:ok, bytes} <- read_at_most(handle, @max_bytes + 1, [], name),
               :ok <- seam(:after_read, {name, bytes}) do
            if byte_size(bytes) <= @max_bytes,
              do: {:ok, bytes},
              else: {:error, {name, :too_large}}
          end
        after
          :file.close(handle)
        end

      {:error, _reason} ->
        {:error, {name, :unreadable}}
    end
  end

  defp opened_object(handle, name, checked) do
    with {:ok, info} <- :file.read_file_info(handle, time: :posix),
         opened = File.Stat.from_record(info),
         true <- opened.type == :regular and same_object?(opened, checked),
         {:ok, _stat} <- private_stat(opened, name) do
      :ok
    else
      {:error, {^name, _rule}} = error -> error
      _changed -> {:error, {name, :changed}}
    end
  end

  defp same_object?(a, b),
    do:
      a.inode == b.inode and a.major_device == b.major_device and a.minor_device == b.minor_device

  # At most `left` bytes in total, however the reads are split.
  defp read_at_most(_handle, 0, acc, _name), do: {:ok, :erlang.iolist_to_binary(acc)}

  defp read_at_most(handle, left, acc, name) do
    case :file.read(handle, left) do
      {:ok, data} -> read_at_most(handle, left - byte_size(data), [acc, data], name)
      :eof -> {:ok, :erlang.iolist_to_binary(acc)}
      {:error, _reason} -> {:error, {name, :unreadable}}
    end
  end

  defp hex(bin), do: Base.encode16(bin, case: :lower)

  defp decode_all(bins) do
    Enum.reduce_while(Enum.sort(@files), {:ok, %{}}, fn name, {:ok, acc} ->
      key = @keys[name]

      case BoundedJson.decode(bins[key],
             max_bytes: @max_bytes,
             max_depth: @depth[name],
             known_keys: @known_keys
           ) do
        {:ok, doc} -> {:cont, {:ok, Map.put(acc, key, doc)}}
        {:error, {path, rule}} -> {:halt, {:error, {at(name, path), rule}}}
      end
    end)
  end

  ## The content files

  defp profile(doc) do
    in_file("offering_profile.json", fn ->
      with :ok <- Rules.keys(doc, ~w(name summary audience items), []),
           :ok <- string(doc["name"], "name"),
           :ok <- string(doc["summary"], "summary"),
           :ok <- string(doc["audience"], "audience"),
           :ok <- Rules.list(doc["items"], "items", 1, 30) do
        items(doc["items"])
      end
    end)
  end

  defp items(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while(MapSet.new(), fn {item, k}, ids ->
      p = "items[#{k}]"

      with :ok <- Rules.keys(item, ~w(id kind text), ["items", k]),
           :ok <- string(item["id"], "#{p}.id"),
           :ok <- Rules.enum(item["kind"], @item_kinds, "#{p}.kind"),
           :ok <- string(item["text"], "#{p}.text"),
           false <- MapSet.member?(ids, item["id"]) do
        {:cont, MapSet.put(ids, item["id"])}
      else
        true -> {:halt, {:error, {"#{p}.id", :duplicate}}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _ids -> :ok
    end
  end

  defp guide(doc) do
    in_file("writing_guide.json", fn ->
      with :ok <- Rules.keys(doc, ["text"], []), do: string(doc["text"], "text")
    end)
  end

  defp sender_in_guide(doc) do
    if :binary.match(doc["text"], @sender_name) != :nomatch,
      do: :ok,
      else: {:error, {"writing_guide.json:text", :sender}}
  end

  defp campaign(doc), do: in_file("campaign.json", fn -> campaign_rules(doc) end)

  defp campaign_rules(doc) do
    with :ok <- Rules.keys(doc, ~w(icp sequence sender_name), []),
         :ok <- icp(doc["icp"]),
         :ok <- sequence(doc["sequence"]),
         :ok <- string(doc["sender_name"], "sender_name") do
      sender_name(doc["sender_name"])
    end
  end

  defp sender_name(@sender_name), do: :ok
  defp sender_name(_other), do: {:error, {"sender_name", :sender}}

  defp icp(icp) do
    with :ok <- Rules.keys(icp, ~w(name description criteria), ["icp"]),
         :ok <- Rules.text(icp["name"], "icp.name", 1, 200),
         :ok <- Rules.text(icp["description"], "icp.description", 1, 2000, true) do
      criteria(icp["criteria"])
    end
  end

  defp criteria(c) do
    keys = ~w(employee_count_min employee_count_max industries geographies personas triggers)

    with :ok <- Rules.keys(c, keys, ["icp", "criteria"]),
         :ok <- count(c["employee_count_min"], "icp.criteria.employee_count_min"),
         :ok <- count(c["employee_count_max"], "icp.criteria.employee_count_max"),
         :ok <- ordered(c["employee_count_min"], c["employee_count_max"]) do
      Enum.find_value(@criteria_lists, :ok, fn {key, max} ->
        nil_if_ok(strings(c[key], "icp.criteria.#{key}", max))
      end)
    end
  end

  defp count(value, p) when is_integer(value),
    do: if(value >= 0, do: :ok, else: {:error, {p, :range}})

  defp count(nil, p), do: {:error, {p, :null}}
  defp count(_value, p), do: {:error, {p, :type}}

  defp ordered(min, max) when max >= min, do: :ok
  defp ordered(_min, _max), do: {:error, {"icp.criteria.employee_count_max", :range}}

  defp strings(list, p, max) do
    with :ok <- Rules.list(list, p, 1, max) do
      list
      |> Enum.with_index()
      |> Enum.find_value(:ok, &string_item(&1, p))
    end
  end

  defp string_item({s, k}, p) do
    sp = "#{p}[#{k}]"

    cond do
      not is_binary(s) -> {:error, {sp, :type}}
      String.length(s) not in 1..400 -> {:error, {sp, :length}}
      true -> nil_if_ok(Rules.text(s, sp, 1, 400))
    end
  end

  # For Enum.find_value/3: nil continues, an error stops.
  defp nil_if_ok(:ok), do: nil
  defp nil_if_ok(error), do: error

  defp sequence(seq) do
    with :ok <- Rules.keys(seq, ~w(name step), ["sequence"]),
         :ok <- Rules.text(seq["name"], "sequence.name", 1, 200),
         :ok <- step(seq["step"]) do
      string(seq["step"]["instructions"], "sequence.step.instructions")
    end
  end

  defp step(%{} = step), do: Rules.keys(step, ["instructions"], ["sequence", "step"])
  defp step(nil), do: {:error, {"sequence.step", :null}}
  defp step(_other), do: {:error, {"sequence.step", :type}}

  ## Provenance

  defp provenance(doc, profile, sha256s) do
    in_file("provenance.json", fn ->
      with :ok <- Rules.keys(doc, ~w(schema schema_version files entries), []),
           :ok <- same(doc["schema"], @provenance_schema, "schema", :schema),
           :ok <- same(doc["schema_version"], 1, "schema_version", :schema_version),
           :ok <- files_digests(doc["files"], sha256s),
           :ok <- Rules.list(doc["entries"], "entries", 1, 64) do
        entries_refs(doc["entries"], ref_classes(profile))
      end
    end)
  end

  defp files_digests(files, sha256s) do
    with :ok <- Rules.keys(files, ~w(offering_profile writing_guide campaign), ["files"]) do
      Enum.find_value(@content_files, :ok, &file_digest(&1, files, sha256s))
    end
  end

  defp file_digest({key, atom}, files, sha256s) do
    if files[key] == sha256s[atom], do: nil, else: {:error, {"files.#{key}", :files_digest}}
  end

  # ref => :claim | :instruction | :targeting, derived from the ref itself.
  defp ref_classes(profile) do
    fixed = %{
      "profile.name" => :claim,
      "profile.summary" => :claim,
      "profile.audience" => :targeting,
      "guide" => :instruction,
      "campaign.icp" => :targeting,
      "campaign.step" => :instruction
    }

    items =
      Map.new(profile["items"], fn item ->
        {"item:#{item["id"]}", if(item["kind"] in @claim_kinds, do: :claim, else: :instruction)}
      end)

    Map.merge(fixed, items)
  end

  defp entries_refs(entries, classes) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while(MapSet.new(), fn {entry, k}, seen ->
      case entry(entry, k, classes, seen) do
        :ok -> {:cont, MapSet.put(seen, entry["ref"])}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _} = error ->
        error

      seen ->
        if MapSet.equal?(seen, MapSet.new(Map.keys(classes))),
          do: :ok,
          else: {:error, {"entries", :ref_missing}}
    end
  end

  defp entry(entry, k, classes, seen) do
    p = "entries[#{k}]"

    with :ok <- Rules.keys(entry, ~w(ref public sources), ["entries", k]),
         :ok <- ref(entry["ref"], classes, seen, "#{p}.ref"),
         :ok <- boolean(entry["public"], "#{p}.public"),
         :ok <- Rules.list(entry["sources"], "#{p}.sources", 1, 6),
         :ok <- sources(entry["sources"], p),
         :ok <- claim_public(entry, classes, p) do
      public_sources(entry, p)
    end
  end

  defp ref(ref, classes, seen, p) do
    cond do
      not is_binary(ref) or not Map.has_key?(classes, ref) -> {:error, {p, :ref_unknown}}
      MapSet.member?(seen, ref) -> {:error, {p, :ref_duplicate}}
      true -> :ok
    end
  end

  defp sources(sources, p) do
    sources
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {s, m} ->
      sp = "#{p}.sources[#{m}]"

      result =
        with :ok <- Rules.keys(s, ~w(kind ref retrieved_on), segments(p) ++ ["sources", m]),
             :ok <- Rules.enum(s["kind"], ~w(public_url repo_path), "#{sp}.kind"),
             :ok <- source_ref(s["kind"], s["ref"], "#{sp}.ref") do
          Rules.date(s["retrieved_on"], "#{sp}.retrieved_on")
        end

      if result == :ok, do: nil, else: result
    end)
  end

  defp source_ref("public_url", ref, p), do: Rules.url(ref, p)
  defp source_ref("repo_path", ref, p), do: Rules.pattern(ref, @repo_ref, p)

  defp claim_public(%{"ref" => ref, "public" => public}, classes, p) do
    if classes[ref] == :claim and public != true,
      do: {:error, {"#{p}.public", :claim_not_public}},
      else: :ok
  end

  defp public_sources(%{"public" => true, "sources" => sources}, p) do
    case Enum.find_index(sources, &(&1["kind"] != "public_url")) do
      nil -> :ok
      m -> {:error, {"#{p}.sources[#{m}].kind", :public_source}}
    end
  end

  defp public_sources(_entry, _p), do: :ok

  ## Helpers

  # Runs `fun` (which reports paths inside one file) and prefixes the file.
  defp in_file(name, fun) do
    case fun.() do
      :ok -> :ok
      {:error, {path, rule}} -> {:error, {at(name, path), rule}}
    end
  end

  defp at(name, "(root)"), do: name
  defp at(name, path), do: "#{name}:#{path}"

  defp string(value, _p) when is_binary(value), do: :ok
  defp string(nil, p), do: {:error, {p, :null}}
  defp string(_value, p), do: {:error, {p, :type}}

  defp boolean(value, _p) when is_boolean(value), do: :ok
  defp boolean(nil, p), do: {:error, {p, :null}}
  defp boolean(_value, p), do: {:error, {p, :type}}

  defp same(value, value, _p, _rule), do: :ok
  defp same(_value, _expected, p, rule), do: {:error, {p, rule}}

  defp segments("entries[" <> rest) do
    {k, "]"} = Integer.parse(rest)
    ["entries", k]
  end

  # Test-seam builds only (`:claude_cli_test_seams`, fixed at compile time):
  # a test may act or observe at a named boundary of `read/2` through a
  # one-argument function in its own process dictionary under
  # `{SdrAgent.Prototype.SeedDir, name}`: `:after_precheck` (the directory,
  # once every lstat check passed and before any file is opened),
  # `:after_open` (`{file name, handle}` once the opened object and the root
  # are checked, before any byte is read) and `:after_read` (`{file name,
  # bytes}` right after the bounded read, before its size and digest
  # checks). Its return value is ignored: a hook can act on the filesystem,
  # never skip a check. Every other build compiles `seam/2` to `:ok`.
  if @test_seams do
    defp seam(name, arg) do
      case Process.get({__MODULE__, name}) do
        hook when is_function(hook, 1) -> hook.(arg)
        _none -> nil
      end

      :ok
    end
  else
    defp seam(_name, _arg), do: :ok
  end
end
