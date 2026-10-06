This is a web application written using the Phoenix web framework.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- **Always** manually write your own tailwind-based components instead of using daisyUI for a unique, world-class design
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions


<!-- >>> workflow-factory:workflow-doctrine >>> -->

# Core Principles

## Priority Order

- Correctness over velocity.
- Explicitness over magic.
- Maintainability over short-lived convenience.

## Working Rules

- Read before editing and follow established local patterns.
- Make the smallest correct change; do not add speculative refactors.
- Prefer executable invariants and tests over prose-only promises.
- Report exact failures, affected paths, and verification evidence.


# Engineering Workflow

1. Classify the request and affected areas.
2. Explore read-only until behavior and constraints are understood.
3. For non-trivial work, use the plan template to record scope, acceptance,
   risks, and required decisions.
4. Obtain required approval before implementation.
5. Define observable behavior, then implement the smallest approved change.
6. Run targeted checks and the full gate.
7. Review correctness, security, scope, and documentation drift.

Keep updates concise: established facts, current hypothesis, and next action.
Humans own correctness, security, public interfaces, and architecture.


# Error Recovery

1. Read the complete error and preserve the failing reproduction.
2. Fix the specific defect without adjacent refactoring.
3. Re-run the narrow failing check, then the broader gate.
4. Change an assertion only when evidence shows the assertion is wrong.

Never silence failures, bypass security controls, weaken assertions to obtain a
pass, or replace a tracked problem with an unowned TODO.


# Security Guardrails

- Never expose, log, or commit credentials and private keys.
- Never pipe downloaded content directly into a shell.
- Require explicit approval for destructive filesystem, database, or history
  rewriting operations.
- Do not weaken authentication, authorization, validation, or transport
  protections to make a check pass.
- Review generated and copied configuration for secret material before commit.


# Workflow Skills

This index is generated from workflow skill frontmatter; dependency-generated
skills are outside its scope.

<!-- workflow-skill-index:start -->
| Skill |
|---|
| `adr` |
| `architecture-diagram` |
| `debug-bundle` |
| `entity-discovery` |
| `handoff` |
| `implement` |
| `plan` |
| `pr-ready` |
| `project-factory` |
| `repo-map` |
| `review` |
| `static-analysis` |
| `tdd-verify` |
| `test-runner` |
<!-- workflow-skill-index:end -->


# Definition of Done

A change is complete only when:

- acceptance behavior is covered by focused checks;
- the repository's full verification gate passes;
- regression coverage exists for behavior changes;
- the diff contains no secrets or weakened protections;
- required decision records and maintained documentation are current; and
- the final report names verification performed and any remaining risk.


# Architecture Decisions

Create an ADR for material alternatives, technologies, cross-cutting patterns,
durable boundaries, future constraints, or explicit architecture. Routine work
within an accepted pattern needs none.

Reused gate mechanics are process conventions unless they add a technology,
dependency, reviewer boundary, cross-cutting tradeoff, or tooling constraint.

States: `proposed`, `accepted`, `deprecated`, `superseded`. Acceptance requires
approval; superseding ADRs name predecessors. Automate enforceable constraints.


# Environment Constraints

- Treat repository-local environment declarations as authoritative.
- Verify required tools before beginning implementation.
- Do not suggest unavailable package managers, service managers, or
  virtualization tools when project facts rule them out.
- Keep project names, ports, services, topology, and machine-specific facts in
  project-owned configuration rather than managed doctrine.


# Entity Model

Require an entity-model delta for changed persisted concepts, meaningful
attributes/invariants, relationships/cardinality, ownership/authorization,
lifecycles, or backend action contracts. Otherwise record why no trigger applies.

Resolve it before affected modules and ADR evaluation. Include existing entities
only for changed relationships, policies, or lifecycles.

Use `entity-discovery` and submit its table to an independent reviewer. Reviewer
precedence is correlated `ap` review when `ai_pair=true`, a Codex plugin
subagent when `ai_pair=false` and `codex_review=true`, then named explicit human sign-off.
Record `PASS`, `NEEDS-REVIEW`, `BLOCKED`, or `UNREVIEWED` with
the reviewer and evidence; only `PASS` permits approval. No self-review.


# Elixir Architecture Artifacts

Evaluate diagrams after changes to app boundaries, supervision, public runtime
flows, endpoints, channels, or integrations. Ignore local details, tests,
documentation, and behavior within an existing boundary.

Review generated diagrams for runtime-only and conditional relationships.


# AST and Architecture Tools

- Use AST rewrites for structural changes brittle under text replacement; review
  the diff.
- Keep graph checks advisory until a baseline is reviewed.
- Never run repository-wide auto-fixes during TDD.
- Add analysis packages or exclusions only with project evidence.

Load `static-analysis` for versions, setup, and caveats.


# Elixir and OTP Principles

- Prefer compile-time feedback and explicit data flow.
- Create processes for concurrency, state isolation, or fault tolerance, never
  organization alone.
- Treat GenServers as serialized bottlenecks; use better read-heavy structures.
- Design supervision recovery deliberately; account for crash impact.
- Match behaviours, protocols, or messages to the modeled boundary.


# Elixir Definition of Done

- `mix format --check-formatted` passes.
- `mix compile --warnings-as-errors` passes.
- Focused and full ExUnit suites pass.
- Configured static-analysis checks pass at their declared enforcement level.
- Generated code has been reviewed for local directive and documentation rules.


# Development Environment

When Nix is selected, track project-local `flake.nix`, `devenv.nix`, and
`.envrc`; enter that environment before verification.

Record explicit service ports in all linked configuration. Diagnose collisions
with `lsof -nP -iTCP:PORT -sTCP:LISTEN`; never change ports silently.

Use `devenv up`; verify readiness before database work.


# Elixir Error Recovery

## Compilation

1. Read the complete diagnostic.
2. Fix the named error without adjacent refactoring.
3. Run `mix compile --warnings-as-errors`.
4. Use a forced compile only when stale compilation state is demonstrated.

## Tests

Run `mix test path/to/test.exs:LINE`, fix the root cause without weakening the
assertion, then run the broader suite.


# Static Analysis

Initially block on format, warnings-as-errors compilation, ExUnit, and Credo;
add Sobelow for Phoenix. Dependency audits remain advisory until promoted.

Dialyzer, graph checks, duplicate detection, and other expensive or
baseline-dependent tools are opt-in. Review a baseline before enforcement. Use
`static-analysis` for package and configuration guidance.


# Elixir Style

Order directives by group: `@moduledoc`, `@behaviour`, `use`, `import`,
`require`, `alias`, attributes, structs/types, callbacks, definitions. Separate
groups and sort within them.

Every public module needs a meaningful `@moduledoc`; use `@moduledoc false` only
for implementation details. Review generated files for this convention.


# TDD Cycle

For non-trivial behavior:

1. RED: write a happy-path test and relevant failure-path tests.
2. Confirm failure for the intended missing behavior.
3. GREEN: implement only enough to pass.
4. REFACTOR: improve structure while the tests remain green.

No production behavior during RED or untested scope during GREEN. Use
`tdd-verify` for the RED gate.


# Elixir Testing

- Start non-trivial behavior with an ExUnit assertion that fails for the intended
  reason, not setup or compilation.
- Cover success and a relevant failure or boundary; run focused then broad tests.
- Do not seed shared mutable data in `test_helper.exs`; use per-test setup.
- Never weaken assertions to match defects. Use `tdd-verify` for phased TDD.


# Tidewave

When a Phoenix endpoint and project-scoped Tidewave MCP are reachable, use
runtime source, documentation, and evaluation tools before guessing. If the
endpoint is unavailable, state that fact and use file reads, search, compile,
and server output instead. Never fabricate MCP results.

The project-scoped URL must use the same explicit HTTP port as the endpoint.
Do not place a project-specific Tidewave URL in global agent configuration.


# Dependency Usage Rules

When selected by the recipe, keep `usage_rules` as a development dependency.
Use `mix usage_rules.search_docs "term"` before guessing at dependency APIs and
run `mix usage_rules.sync` after dependency additions or upgrades.

Generated dependency skills remain generator-owned. Do not hand-edit them or
list them as workflow-owned skills.

Generated skill directory names must be kebab-case, and each skill's
frontmatter `name` must exactly match its directory. Projection rejects any
other generated namespace.


# Elixir Workflow

- Work from the project root and identify the owning app before edits.
- Check available generators before hand-authoring framework structure.
- Start non-trivial behavior with focused ExUnit coverage.
- After each coherent step, run the focused test and
  `mix compile --warnings-as-errors`.
- Before completion, run all format, compile, analysis, and test gates; review
  public modules for meaningful `@moduledoc` content.

For Phoenix, keep data loading out of `mount/3`, pass authorization through the
project scope, prevent PubSub self-echoes with `broadcast_from/4`, and treat
socket state as stale. New projects require browser security headers and
production TLS redirects.


# Ash Architecture Artifacts

Regenerate domain diagrams for new domains or resources, resource moves,
cross-domain data flow, or changed ownership boundaries. Attribute-only or
action-only changes inside an existing boundary do not require regeneration.


# Ash Architecture

## Mutations

Use domain APIs or `Ash.Changeset.for_create/for_update`. Direct resource struct
mutation and raw Ecto changesets over Ash resources are forbidden.

## Boundaries

- Domain modules own resources, policies, actions, persistence, and business
  invariants.
- Web modules orchestrate through public domain APIs; they do not contain
  resources or direct Repo access.
- Dependency direction points from web and worker layers toward the domain.
- Cross-domain references use stable identifiers and explicit public APIs.

Actions must be explicit, minimal, and policy-protected. Prefer constrained
types, relationship constraints, and identities over late runtime validation.


# Ash Analyzer Constraints

Architecture analyzers supplement rather than replace Ash policies, actions,
validations, and authorization. Do not ship guessed exclusions for DSL macros.
Keep query-edge and generated-code checks advisory until verified against the
target application's real resource and web boundaries.


# Ash Principles

- Ash resources, actions, validations, and policies are the domain write surface.
- Prefer DSL constraints and policy checks that make invalid states difficult to
  represent.
- Run code generation and validation early so DSL failures surface quickly.
- Never mutate resource structs directly or route around policies for speed.
- Keep resources explicit and test important invariants through domain APIs.


# Ash Definition of Done

- Resource and domain boundaries remain intact.
- Actions are exercised through domain APIs.
- Policy changes have allow and deny coverage.
- No resource struct is mutated directly and no raw persistence path bypasses
  actions or policies.
- Required code generation and domain diagrams are current.


# Ash Error Recovery

- For `Ash.Error.Forbidden`, verify actor propagation and policy expectations.
- For `Ash.Error.Invalid`, inspect action inputs, validations, and changeset
  errors.
- Repair the action or policy path; never bypass authorization or fall back to a
  raw persistence write.


# Ash Security

- Never bypass or weaken policies to make behavior or tests pass.
- Propagate the actor through every public action path that requires one.
- Policy tests include explicit allow and deny scenarios.
- Treat changes to ownership and authorization boundaries as entity-model and
  security-review triggers.


# Ash Module Documentation

Resource moduledocs identify the domain concept, important attributes,
relationships, constraints, and caller-facing actions. Domain moduledocs name
the bounded context, resources it owns, and supported cross-domain
interactions. Custom actions document their state transition, inputs, side
effects, and authorization expectations.


# Ash Testing

- Exercise resources through domain APIs and actions.
- New attributes need default, validation, and nil-handling coverage where
  applicable.
- New actions need success, relevant failure, and authorization scenarios.
- Policy changes require explicit allow and deny cases.
- Do not mock Ash domain behavior or manipulate internal changesets as the
  subject of an application test.


# Ash Workflow

- During planning, resolve entity, attribute, relationship, invariant,
  ownership, and lifecycle changes before choosing affected modules.
- Check `mix ash.gen.*` tasks before hand-authoring resource structure.
- Test behavior through domain actions and APIs rather than internal changeset
  construction.
- Run code generation when resource changes require persistence artifacts.
- Evaluate domain-boundary diagrams after new domains, resources, cross-domain
  flows, or ownership boundaries.
<!-- <<< workflow-factory:workflow-doctrine <<< -->
<!-- usage-rules-start -->
<!-- ash-start -->
## ash usage
_A declarative, extensible framework for building Elixir applications._

[ash usage rules](deps/ash/usage-rules.md)
<!-- ash-end -->
<!-- ash:actions-start -->
## ash:actions usage
[ash:actions usage rules](deps/ash/usage-rules/actions.md)
<!-- ash:actions-end -->
<!-- ash:aggregates-start -->
## ash:aggregates usage
[ash:aggregates usage rules](deps/ash/usage-rules/aggregates.md)
<!-- ash:aggregates-end -->
<!-- ash:authorization-start -->
## ash:authorization usage
[ash:authorization usage rules](deps/ash/usage-rules/authorization.md)
<!-- ash:authorization-end -->
<!-- ash:calculations-start -->
## ash:calculations usage
[ash:calculations usage rules](deps/ash/usage-rules/calculations.md)
<!-- ash:calculations-end -->
<!-- ash:code_interfaces-start -->
## ash:code_interfaces usage
[ash:code_interfaces usage rules](deps/ash/usage-rules/code_interfaces.md)
<!-- ash:code_interfaces-end -->
<!-- ash:code_structure-start -->
## ash:code_structure usage
[ash:code_structure usage rules](deps/ash/usage-rules/code_structure.md)
<!-- ash:code_structure-end -->
<!-- ash:data_layers-start -->
## ash:data_layers usage
[ash:data_layers usage rules](deps/ash/usage-rules/data_layers.md)
<!-- ash:data_layers-end -->
<!-- ash:exist_expressions-start -->
## ash:exist_expressions usage
[ash:exist_expressions usage rules](deps/ash/usage-rules/exist_expressions.md)
<!-- ash:exist_expressions-end -->
<!-- ash:generating_code-start -->
## ash:generating_code usage
[ash:generating_code usage rules](deps/ash/usage-rules/generating_code.md)
<!-- ash:generating_code-end -->
<!-- ash:migrations-start -->
## ash:migrations usage
[ash:migrations usage rules](deps/ash/usage-rules/migrations.md)
<!-- ash:migrations-end -->
<!-- ash:query_filter-start -->
## ash:query_filter usage
[ash:query_filter usage rules](deps/ash/usage-rules/query_filter.md)
<!-- ash:query_filter-end -->
<!-- ash:querying_data-start -->
## ash:querying_data usage
[ash:querying_data usage rules](deps/ash/usage-rules/querying_data.md)
<!-- ash:querying_data-end -->
<!-- ash:relationships-start -->
## ash:relationships usage
[ash:relationships usage rules](deps/ash/usage-rules/relationships.md)
<!-- ash:relationships-end -->
<!-- ash:testing-start -->
## ash:testing usage
[ash:testing usage rules](deps/ash/usage-rules/testing.md)
<!-- ash:testing-end -->
<!-- ash_authentication-start -->
## ash_authentication usage
_Authentication extension for the Ash Framework._

[ash_authentication usage rules](deps/ash_authentication/usage-rules.md)
<!-- ash_authentication-end -->
<!-- ash_phoenix-start -->
## ash_phoenix usage
_Utilities for integrating Ash and Phoenix_

[ash_phoenix usage rules](deps/ash_phoenix/usage-rules.md)
<!-- ash_phoenix-end -->
<!-- ash_phoenix:best_practices-start -->
## ash_phoenix:best_practices usage
[ash_phoenix:best_practices usage rules](deps/ash_phoenix/usage-rules/best_practices.md)
<!-- ash_phoenix:best_practices-end -->
<!-- ash_phoenix:debugging_form_submissions-start -->
## ash_phoenix:debugging_form_submissions usage
[ash_phoenix:debugging_form_submissions usage rules](deps/ash_phoenix/usage-rules/debugging_form_submissions.md)
<!-- ash_phoenix:debugging_form_submissions-end -->
<!-- ash_phoenix:error_handling-start -->
## ash_phoenix:error_handling usage
[ash_phoenix:error_handling usage rules](deps/ash_phoenix/usage-rules/error_handling.md)
<!-- ash_phoenix:error_handling-end -->
<!-- ash_phoenix:form_integration-start -->
## ash_phoenix:form_integration usage
[ash_phoenix:form_integration usage rules](deps/ash_phoenix/usage-rules/form_integration.md)
<!-- ash_phoenix:form_integration-end -->
<!-- ash_phoenix:nested_forms-start -->
## ash_phoenix:nested_forms usage
[ash_phoenix:nested_forms usage rules](deps/ash_phoenix/usage-rules/nested_forms.md)
<!-- ash_phoenix:nested_forms-end -->
<!-- ash_phoenix:union_forms-start -->
## ash_phoenix:union_forms usage
[ash_phoenix:union_forms usage rules](deps/ash_phoenix/usage-rules/union_forms.md)
<!-- ash_phoenix:union_forms-end -->
<!-- ash_postgres-start -->
## ash_postgres usage
_The PostgreSQL data layer for Ash Framework_

[ash_postgres usage rules](deps/ash_postgres/usage-rules.md)
<!-- ash_postgres-end -->
<!-- ash_postgres:advanced_features-start -->
## ash_postgres:advanced_features usage
[ash_postgres:advanced_features usage rules](deps/ash_postgres/usage-rules/advanced_features.md)
<!-- ash_postgres:advanced_features-end -->
<!-- ash_postgres:best_practices-start -->
## ash_postgres:best_practices usage
[ash_postgres:best_practices usage rules](deps/ash_postgres/usage-rules/best_practices.md)
<!-- ash_postgres:best_practices-end -->
<!-- ash_postgres:check_constraints-start -->
## ash_postgres:check_constraints usage
[ash_postgres:check_constraints usage rules](deps/ash_postgres/usage-rules/check_constraints.md)
<!-- ash_postgres:check_constraints-end -->
<!-- ash_postgres:configuration-start -->
## ash_postgres:configuration usage
[ash_postgres:configuration usage rules](deps/ash_postgres/usage-rules/configuration.md)
<!-- ash_postgres:configuration-end -->
<!-- ash_postgres:custom_indexes-start -->
## ash_postgres:custom_indexes usage
[ash_postgres:custom_indexes usage rules](deps/ash_postgres/usage-rules/custom_indexes.md)
<!-- ash_postgres:custom_indexes-end -->
<!-- ash_postgres:custom_sql_statements-start -->
## ash_postgres:custom_sql_statements usage
[ash_postgres:custom_sql_statements usage rules](deps/ash_postgres/usage-rules/custom_sql_statements.md)
<!-- ash_postgres:custom_sql_statements-end -->
<!-- ash_postgres:foreign_keys-start -->
## ash_postgres:foreign_keys usage
[ash_postgres:foreign_keys usage rules](deps/ash_postgres/usage-rules/foreign_keys.md)
<!-- ash_postgres:foreign_keys-end -->
<!-- ash_postgres:migrations-start -->
## ash_postgres:migrations usage
[ash_postgres:migrations usage rules](deps/ash_postgres/usage-rules/migrations.md)
<!-- ash_postgres:migrations-end -->
<!-- ash_postgres:multitenancy-start -->
## ash_postgres:multitenancy usage
[ash_postgres:multitenancy usage rules](deps/ash_postgres/usage-rules/multitenancy.md)
<!-- ash_postgres:multitenancy-end -->
<!-- igniter-start -->
## igniter usage
_A code generation and project patching framework_

[igniter usage rules](deps/igniter/usage-rules.md)
<!-- igniter-end -->
<!-- phoenix:ecto-start -->
## phoenix:ecto usage
[phoenix:ecto usage rules](deps/phoenix/usage-rules/ecto.md)
<!-- phoenix:ecto-end -->
<!-- phoenix:elixir-start -->
## phoenix:elixir usage
[phoenix:elixir usage rules](deps/phoenix/usage-rules/elixir.md)
<!-- phoenix:elixir-end -->
<!-- phoenix:html-start -->
## phoenix:html usage
[phoenix:html usage rules](deps/phoenix/usage-rules/html.md)
<!-- phoenix:html-end -->
<!-- phoenix:liveview-start -->
## phoenix:liveview usage
[phoenix:liveview usage rules](deps/phoenix/usage-rules/liveview.md)
<!-- phoenix:liveview-end -->
<!-- phoenix:phoenix-start -->
## phoenix:phoenix usage
[phoenix:phoenix usage rules](deps/phoenix/usage-rules/phoenix.md)
<!-- phoenix:phoenix-end -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

[usage_rules usage rules](deps/usage_rules/usage-rules.md)
<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
[usage_rules:elixir usage rules](deps/usage_rules/usage-rules/elixir.md)
<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
[usage_rules:otp usage rules](deps/usage_rules/usage-rules/otp.md)
<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->
