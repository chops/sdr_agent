defmodule SdrAgent.DossierFixtures do
  @moduledoc """
  Synthetic inputs for the D-237 S3 tests (interfaces r6 IF-6, IF-7): the
  `sdr-agent.prototype-dossier` v1 dossier, the `sdr-agent.prototype-spotcheck`
  v1 manifest, retained source artifacts and the four-file GTM seed
  directory. Every value here is invented `.test`/`.example` data written
  for the tests; nothing is read from, or copied out of, a private file.

  - `dossier/1`, `company/2`, `claim/4` build a valid dossier whose flagged
    rows pass the whole importable rule against `manifest/2`.
  - `manifest/2` builds a manifest that verifies every claim and every fact
    with an excerpt of the given rows, with the relation each item needs.
  - `encode/1`, `sha256/1`; `scratch_dir!/1`, `write!/3`.
  - `seed_contents/0` and `write_seed_dir!/2` build a valid seed directory
    and return its four digests.
  """

  @checked_at "2026-10-27T10:00:00-06:00"

  @doc "The spot-check time every fixture result carries."
  def checked_at, do: @checked_at

  @doc "A valid dossier holding `companies`."
  def dossier(companies \\ [company(1)]) do
    %{
      "schema" => "sdr-agent.prototype-dossier",
      "schema_version" => 1,
      "generated_at" => "2026-10-27T12:00:00-06:00",
      "sources_policy" => "Synthetic test sources only; nothing here names a real person.",
      "companies" => companies
    }
  end

  @doc """
  A valid flagged (importable) row `i`: two company-site sources, a dated
  size quote, a dated location fact, an undated fact, an inference, and a
  contact whose three claims are published on the company team page.
  """
  def company(i, overrides \\ %{}) do
    domain = "acme#{i}.test"
    name = person(i)
    email = "#{first(i)}@#{domain}"

    %{
      "row_id" => "row-#{i}",
      "name" => "Acme #{i} Logistics Software",
      "domain" => domain,
      "why_fit" => "Synthetic fit note #{i}: a small B2B software vendor.",
      "importable" => true,
      "skip_reason" => nil,
      "sources" => [
        source("s1", "https://#{domain}/team", "company_site"),
        source("s2", "https://www.#{domain}/about", "company_site")
      ],
      "facts" => [
        %{
          "fact_id" => "f1",
          "kind" => "quote",
          "topic" => "size",
          "stated_on" => "2026-09-01",
          "text" => "Acme #{i} has a team of 24 people.",
          "source_id" => "s2",
          "excerpt" => "Acme #{i} has a team of 24 people."
        },
        %{
          "fact_id" => "f2",
          "kind" => "fact",
          "topic" => "location",
          "stated_on" => "2026-09-01",
          "text" => "Acme #{i} is based in Denver, Colorado.",
          "source_id" => "s2",
          "excerpt" => "Our whole team works from Denver, Colorado."
        },
        %{
          "fact_id" => "f3",
          "kind" => "fact",
          "topic" => "industry",
          "stated_on" => nil,
          "text" => "Acme #{i} sells routing software to freight brokers.",
          "source_id" => "s2",
          "excerpt" => "We build routing software for freight brokers."
        },
        %{
          "fact_id" => "f4",
          "kind" => "inference",
          "topic" => nil,
          "stated_on" => nil,
          "text" => "Probably needs outbound help soon.",
          "source_id" => nil,
          "excerpt" => nil
        }
      ],
      "contact" => %{
        "name" => name,
        "role" => "Head of Growth",
        "email" => email,
        "email_kind" => "personal_work",
        "classification" => "unverified",
        "confidence" => "high",
        "conflict" => nil,
        "evidence" => %{
          "name" => claim("s1", "company_published", nil, "#{name}, Head of Growth"),
          "role" => claim("s1", "company_published", nil, "#{name}, Head of Growth"),
          "email" => claim("s1", "company_published", nil, "#{name}: #{email}")
        }
      }
    }
    |> Map.merge(overrides)
  end

  @doc "One source of type `type` at `url` (original and final URL equal)."
  def source(id, url, type) do
    %{
      "source_id" => id,
      "original_url" => url,
      "final_url" => url,
      "source_type" => type,
      "retrieved_on" => "2026-10-26",
      "retrieved_at" => nil
    }
  end

  @doc "One contact claim."
  def claim(source_id, basis, attribution, excerpt, artifact \\ nil) do
    %{
      "source_id" => source_id,
      "basis" => basis,
      "attribution_excerpt" => attribution,
      "excerpt" => excerpt,
      "artifact" => artifact
    }
  end

  @doc "The synthetic contact name of row `i`."
  def person(i), do: "#{String.capitalize(first(i))} Testperson"

  defp first(i), do: Enum.at(~w(jordan riley casey morgan avery quinn), rem(i - 1, 6))

  @doc "Replaces the value at `path` (string keys and list indices) in `term`."
  def put(term, path, value), do: put_in(term, access(path), value)

  @doc "Updates the value at `path` with `fun`."
  def update(term, path, fun), do: update_in(term, access(path), fun)

  defp access(path),
    do:
      Enum.map(path, fn
        i when is_integer(i) -> Access.at(i)
        k -> k
      end)

  @doc """
  A manifest for `dossier` (`{map, sha256}`) verifying every claim and every
  fact with an excerpt of `row_ids` (default: every flagged row).
  """
  def manifest({dossier, sha256}, opts \\ []) do
    rows =
      Enum.filter(dossier["companies"], fn row ->
        row["row_id"] in Keyword.get_lazy(opts, :rows, fn -> flagged(dossier) end)
      end)

    %{
      "schema" => "sdr-agent.prototype-spotcheck",
      "schema_version" => 1,
      "dossier_sha256" => sha256,
      "checker" => "claude_code research-test session:test-0001",
      "results" => Enum.flat_map(rows, &results/1)
    }
  end

  defp flagged(dossier),
    do: for(row <- dossier["companies"], row["importable"], do: row["row_id"])

  @doc """
  The parsed form of a manifest map, as `SdrAgent.Prototype.SpotcheckManifest.parse/3`
  returns it (`sha256`, `checker`, results keyed by `{row_id, item}`), built
  without the parser so selection tests reach the importable rule directly.
  """
  def parsed_manifest(manifest) do
    %{
      sha256: sha256(encode(manifest)),
      checker: manifest["checker"],
      results: Map.new(manifest["results"], &{{&1["row_id"], &1["item"]}, &1})
    }
  end

  @doc "Every manifest result of `row`, each verified with the relation its item needs."
  def results(row) do
    claims =
      for {field, relation} <- [
            {"name", nil},
            {"role", "person_role_current"},
            {"email", "person_address_linked"}
          ],
          claim = get_in(row, ["contact", "evidence", field]),
          claim != nil do
        result(row, "claim:#{field}", claim["source_id"], relation)
      end

    facts =
      for fact <- row["facts"], fact["excerpt"] != nil do
        relation =
          case fact["topic"] do
            "size" -> "company_size_stated"
            "location" -> "company_location_stated"
            _other -> nil
          end

        result(row, "fact:#{fact["fact_id"]}", fact["source_id"], relation)
      end

    claims ++ facts
  end

  @doc "One verified manifest result for `item` of `row`."
  def result(row, item, source_id, relation, status \\ "verified") do
    source = Enum.find(row["sources"], &(&1["source_id"] == source_id))

    %{
      "row_id" => row["row_id"],
      "item" => item,
      "source_id" => source_id,
      "final_url" => source["final_url"],
      "checked_at" => @checked_at,
      "result" => status,
      "relation" => relation
    }
  end

  @doc "JSON bytes of `term`."
  def encode(term), do: Jason.encode!(term)

  @doc "The lowercase sha256 hex of `bin`."
  def sha256(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

  @doc """
  A fresh scratch directory with `mode`, owned by the calling test: its name
  carries 128 random bits (unique across VMs), it is created exclusively
  (`File.mkdir/1` refuses an existing path, so nothing residual is ever
  adopted, chmod-ed or written), and only that created root is removed when
  the test exits. Call it from the test process (a test or its `setup`).
  """
  def scratch_dir!(mode \\ 0o700) do
    name = "d237-s3-test-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    dir = Path.join(System.tmp_dir!(), name)

    case File.mkdir(dir) do
      :ok -> :ok
      {:error, reason} -> raise "scratch root not created exclusively: #{inspect(reason)}"
    end

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    File.chmod!(dir, mode)
    dir
  end

  @doc "Writes `bytes` to `dir/name` with `mode`; returns the path."
  def write!(dir, name, bytes, mode \\ 0o600) do
    path = Path.join(dir, name)
    File.write!(path, bytes)
    File.chmod!(path, mode)
    path
  end

  @doc "An artifact reference `{file, sha256}` for `bytes` written into `dir`."
  def artifact!(dir, name, bytes, mode \\ 0o600) do
    write!(dir, name, bytes, mode)
    %{"file" => name, "sha256" => sha256(bytes)}
  end

  ## Seed

  @doc "The four synthetic seed documents (maps), before encoding."
  def seed_contents do
    profile = %{
      "name" => "Example Routing Desk",
      "summary" => "A synthetic offering used only by the test suite.",
      "audience" => "Small synthetic B2B software teams.",
      "items" => [
        %{"id" => "feature-one", "kind" => "feature", "text" => "Routes synthetic loads."},
        %{"id" => "use-case-one", "kind" => "use_case", "text" => "Plan a synthetic week."},
        %{"id" => "outcome-one", "kind" => "outcome", "text" => "Fewer synthetic delays."},
        %{"id" => "proof-one", "kind" => "proof_point", "text" => "Used by test fixtures."},
        %{"id" => "limit-one", "kind" => "limit", "text" => "No live data integration."}
      ]
    }

    guide = %{
      "text" =>
        "Write plainly and briefly.\nSign every draft as the GTMscape team.\n\tNever invent facts."
    }

    campaign = %{
      "icp" => %{
        "name" => "Synthetic small B2B software",
        "description" => "A human note about the synthetic ICP.",
        "criteria" => %{
          "employee_count_min" => 1,
          "employee_count_max" => 50,
          "industries" => ["B2B software sold to businesses; not consumer apps."],
          "geographies" => ["US", "Canada"],
          "personas" => ["Founder", "Head of Growth"],
          "triggers" => ["hiring its first sales roles"]
        }
      },
      "sequence" => %{
        "name" => "Synthetic first touch",
        "step" => %{"instructions" => "Open with one cited fact and ask one question."}
      },
      "sender_name" => "the GTMscape team"
    }

    %{
      "offering_profile.json" => profile,
      "writing_guide.json" => guide,
      "campaign.json" => campaign
    }
  end

  @doc """
  The provenance document for encoded content files `bytes` (name => binary),
  with one entry per item of `profile` (default: the synthetic profile).
  """
  def provenance(bytes, profile \\ seed_contents()["offering_profile.json"]) do
    public = fn url -> %{"kind" => "public_url", "ref" => url, "retrieved_on" => "2026-10-20"} end

    repo = fn path ->
      %{
        "kind" => "repo_path",
        "ref" => "#{String.duplicate("ab", 20)}:#{path}",
        "retrieved_on" => "2026-10-20"
      }
    end

    items =
      for item <- profile["items"] do
        if item["kind"] == "limit",
          do: %{
            "ref" => "item:#{item["id"]}",
            "public" => false,
            "sources" => [repo.("docs/limits.md")]
          },
          else: %{
            "ref" => "item:#{item["id"]}",
            "public" => true,
            "sources" => [public.("https://docs.example.test/#{item["id"]}")]
          }
      end

    %{
      "schema" => "sdr-agent.prototype-seed-provenance",
      "schema_version" => 1,
      "files" => %{
        "offering_profile" => sha256(bytes["offering_profile.json"]),
        "writing_guide" => sha256(bytes["writing_guide.json"]),
        "campaign" => sha256(bytes["campaign.json"])
      },
      "entries" =>
        [
          %{
            "ref" => "profile.name",
            "public" => true,
            "sources" => [public.("https://docs.example.test/")]
          },
          %{
            "ref" => "profile.summary",
            "public" => true,
            "sources" => [public.("https://docs.example.test/summary")]
          },
          %{"ref" => "profile.audience", "public" => false, "sources" => [repo.("docs/icp.md")]},
          %{"ref" => "guide", "public" => false, "sources" => [repo.("docs/guide.md")]},
          %{"ref" => "campaign.icp", "public" => false, "sources" => [repo.("docs/icp.md")]},
          %{"ref" => "campaign.step", "public" => false, "sources" => [repo.("docs/step.md")]}
        ] ++ items
    }
  end

  @doc """
  Writes a seed directory (0700, files 0600) from `contents` (name => map or
  raw binary; `provenance.json` is derived unless given) and returns
  `{dir, %{offering_profile:, writing_guide:, campaign:, provenance:}}`.
  Options: `dir_mode:`, `file_mode:`, `extra:` (name => binary).
  """
  def write_seed_dir!(contents \\ seed_contents(), opts \\ []) do
    dir = scratch_dir!(Keyword.get(opts, :dir_mode, 0o700))
    mode = Keyword.get(opts, :file_mode, 0o600)
    bytes = Map.new(contents, fn {name, value} -> {name, to_bytes(value)} end)

    bytes =
      Map.put_new_lazy(bytes, "provenance.json", fn ->
        encode(provenance(bytes, profile(contents)))
      end)

    for {name, bin} <- bytes, do: write!(dir, name, bin, mode)
    for {name, bin} <- Keyword.get(opts, :extra, %{}), do: write!(dir, name, bin, mode)

    {dir,
     %{
       offering_profile: sha256(bytes["offering_profile.json"]),
       writing_guide: sha256(bytes["writing_guide.json"]),
       campaign: sha256(bytes["campaign.json"]),
       provenance: sha256(bytes["provenance.json"])
     }}
  end

  defp to_bytes(bin) when is_binary(bin), do: bin
  defp to_bytes(map), do: encode(map)

  defp profile(contents) do
    case contents["offering_profile.json"] do
      %{} = profile -> profile
      _raw -> seed_contents()["offering_profile.json"]
    end
  end
end
