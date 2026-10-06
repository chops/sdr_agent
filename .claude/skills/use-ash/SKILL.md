---
name: use-ash
description: "A declarative, extensible framework for building Elixir applications.."
metadata:
  managed-by: usage-rules
---

<!-- usage-rules-skill-start -->
## Additional References

### ash

- [ash](references/ash/ash.md)
- [actions](references/ash/actions.md)
- [aggregates](references/ash/aggregates.md)
- [authorization](references/ash/authorization.md)
- [calculations](references/ash/calculations.md)
- [code_interfaces](references/ash/code_interfaces.md)
- [code_structure](references/ash/code_structure.md)
- [data_layers](references/ash/data_layers.md)
- [exist_expressions](references/ash/exist_expressions.md)
- [generating_code](references/ash/generating_code.md)
- [migrations](references/ash/migrations.md)
- [query_filter](references/ash/query_filter.md)
- [querying_data](references/ash/querying_data.md)
- [relationships](references/ash/relationships.md)
- [testing](references/ash/testing.md)

## Searching Documentation

```sh
mix usage_rules.search_docs "search term" -p ash
```

## Available Mix Tasks

- `mix ash` - Prints Ash help information
- `mix ash.codegen` - Runs all codegen tasks for any extension on any resource/domain in your application.
- `mix ash.extend` - Adds an extension or extensions to the given domain/resource
- `mix ash.gen.base_resource` - Generates a base resource. This is a module that you can use instead of `Ash.Resource`, for consistency.
- `mix ash.gen.change` - Generates a custom change module.
- `mix ash.gen.custom_expression` - Generates a custom expression module.
- `mix ash.gen.domain` - Generates an Ash.Domain
- `mix ash.gen.enum` - Generates an Ash.Type.Enum
- `mix ash.gen.gettext` - Copies Ash's .pot file for error message translation
- `mix ash.gen.preparation` - Generates a custom preparation module.
- `mix ash.gen.resource` - Generate and configure an Ash.Resource.
- `mix ash.gen.validation` - Generates a custom validation module.
- `mix ash.generate_livebook` - Generates a Livebook for each Ash domain
- `mix ash.generate_policy_charts` - Generates a Mermaid Flow Chart for a given resource's policies.
- `mix ash.generate_resource_diagrams` - Generates Mermaid Resource Diagrams for each Ash domain
- `mix ash.gettext.extract` - Extracts Ash error messages into a .pot file
- `mix ash.install` - Installs Ash into a project. Should be called with `mix igniter.install ash`
- `mix ash.manifest.dump` - Dump the Ash app manifest as JSON
- `mix ash.migrate` - Runs all migration tasks for any extension on any resource/domain in your application.
- `mix ash.patch.extend` - Adds an extension or extensions to the given domain/resource
- `mix ash.reset` - Runs all tear down & setup tasks for any extension on any resource/domain in your application.
- `mix ash.rollback` - Runs all rollback tasks for any extension on any resource/domain in your application.
- `mix ash.set.domains` - Dynamically discovers and updates Ash domains in config.exs
- `mix ash.setup` - Runs all setup tasks for any extension on any resource/domain in your application.
- `mix ash.tear_down` - Runs all tear_down tasks for any extension on any resource/domain in your application.
<!-- usage-rules-skill-end -->
