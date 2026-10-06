---
name: use-ash-postgres
description: "The PostgreSQL data layer for Ash Framework."
metadata:
  managed-by: usage-rules
---

<!-- usage-rules-skill-start -->
## Additional References

### ash_postgres

- [ash_postgres](references/ash_postgres/ash_postgres.md)
- [advanced_features](references/ash_postgres/advanced_features.md)
- [best_practices](references/ash_postgres/best_practices.md)
- [check_constraints](references/ash_postgres/check_constraints.md)
- [configuration](references/ash_postgres/configuration.md)
- [custom_indexes](references/ash_postgres/custom_indexes.md)
- [custom_sql_statements](references/ash_postgres/custom_sql_statements.md)
- [foreign_keys](references/ash_postgres/foreign_keys.md)
- [migrations](references/ash_postgres/migrations.md)
- [multitenancy](references/ash_postgres/multitenancy.md)

## Searching Documentation

```sh
mix usage_rules.search_docs "search term" -p ash_postgres
```

## Available Mix Tasks

- `mix ash_postgres.create` - Creates the repository storage
- `mix ash_postgres.drop` - Drops the repository storage for the repos in the specified (or configured) domains
- `mix ash_postgres.gen.resources` - Generates resources based on a database schema
- `mix ash_postgres.generate_migrations` - Generates migrations, and stores a snapshot of your resources
- `mix ash_postgres.install` - Installs AshPostgres. Should be run with `mix igniter.install ash_postgres`
- `mix ash_postgres.migrate` - Runs the repository migrations for all repositories in the provided (or configured) domains
- `mix ash_postgres.rollback` - Rolls back the repository migrations for all repositories in the provided (or configured) domains
- `mix ash_postgres.setup_vector` - Sets up pgvector for AshPostgres
- `mix ash_postgres.setup_vector.docs`
- `mix ash_postgres.squash_snapshots` - Cleans snapshots folder, leaving only one snapshot per resource
<!-- usage-rules-skill-end -->
