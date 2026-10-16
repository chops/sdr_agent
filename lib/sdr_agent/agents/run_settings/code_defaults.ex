defmodule SdrAgent.Agents.RunSettings.CodeDefaults do
  @moduledoc """
  The built-in defaults of the research brief, writing guide and
  operational limits (C4-R7; `docs/product/c4/readiness.md` sections 3.1,
  3.2 and 3.7; OQ-1, OQ-5). A run whose tenant has not saved a kind binds
  that kind's current default by version and content hash; the offering
  profile and booking link have none.

  Every released version is kept here forever, never edited or removed, so a
  run snapshotted before a deploy still resolves its exact text. Each entry
  is `%{version, content, content_sha256}`: `content` is the atom-keyed
  input map an admin save would send, and `content_sha256` is its
  `c4-settings-content/1` hash (section 3.7), pinned as a literal that was
  computed independently of this code and is pinned again by the golden
  test. At use, `fetch/2` returns an entry only when the hash recomputed
  from its content still equals the pin; otherwise the run's settings fail
  closed (`:settings_default_unavailable`).

  The content is neutral and synthetic: the owner's own guide and brief are
  saved in the app as revisions, never placed in the repository (OQ-5,
  D-123).
  """

  alias SdrAgent.Agents.SettingsRevision

  @writing_guide_1 """
  Write short, plain emails in a friendly, professional tone.
  Open with one specific observation taken from the research, and cite it.
  Connect it to one relevant item of the offering profile.
  Ask one clear question. When no booking link is available, ask a question first; never propose meeting times.
  Do not use hype, superlatives, pressure or claims the evidence does not support.
  Keep a first email under 120 words.\
  """

  @research_brief_1 """
  Research the company from its own public website and recent public sources.
  Describe what the company does, who it serves and how it describes its work.
  Look for public signals that relate to the items of the offering profile.
  Prefer primary sources, record the date of each source, and quote only what a source says.
  When the evidence is thin or conflicting, record an open question instead of guessing.\
  """

  @limits_1 %{
    run_max_model_calls: 20,
    run_max_tool_calls: 60,
    run_max_tokens: 100_000,
    research_max_search_requests: 4,
    research_max_page_fetches: 4,
    research_max_sources: 6,
    research_max_source_chars: 4_000,
    research_max_total_source_chars: 24_000,
    research_max_output_tokens: 2_500,
    research_max_model_calls: 2,
    research_target_seconds: 180,
    research_job_limit_seconds: 600
  }

  @released %{
    offering_profile: [],
    booking_link: [],
    writing_guide: [
      %{
        version: "1",
        content: %{text: @writing_guide_1},
        content_sha256: "9af216ab3fdf3b11536fbb8fcfa47f816891b0a74f4e5cdcd4821e15831d02c3"
      }
    ],
    research_brief: [
      %{
        version: "1",
        content: %{guidance: @research_brief_1, depth: :standard},
        content_sha256: "7f169d445f877e99845bd13871ba096d36aac6ac5db163969b93caa80408d709"
      }
    ],
    operational_limits: [
      %{
        version: "1",
        content: @limits_1,
        content_sha256: "bff11e94226951b449ec75332157de80518b1cc08cfae17803464867e22b0874"
      }
    ]
  }

  @doc "Every released built-in default of `kind`, oldest first (`[]` when it has none)."
  @spec released(atom()) :: [map()]
  def released(kind), do: Map.get(@released, kind, [])

  @doc "The current (latest released) built-in default of `kind`, or nil."
  @spec current(atom()) :: map() | nil
  def current(kind), do: List.last(released(kind))

  @doc """
  The released default `version` of `kind`, `{:ok, entry}` only when the
  hash recomputed from its content equals its pinned `content_sha256`;
  `:error` for an unknown or removed version or a changed hash.
  """
  @spec fetch(atom(), String.t()) :: {:ok, map()} | :error
  def fetch(kind, version) do
    with %{} = entry <- Enum.find(released(kind), &(&1.version == version)),
         true <- content_sha256(kind, entry.content) == entry.content_sha256 do
      {:ok, entry}
    else
      _ -> :error
    end
  end

  @doc """
  The `c4-settings-content/1` hash (section 3.7) of `content` of `kind`,
  as an admin save computes it
  (`SdrAgent.Agents.SettingsRevision.content_sha256/2`).
  """
  @spec content_sha256(atom(), term()) :: String.t()
  def content_sha256(kind, content), do: SettingsRevision.content_sha256(kind, content)
end
