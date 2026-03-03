Create a new deploy-safe Ecto migration following the expand/contract pattern.

## Steps

1. **Ask for the migration purpose** if not already provided. Clarify:
   - What change is being made (add column, create table, add index, remove column, etc.)
   - Whether this is an **expand** phase (adding) or **contract** phase (removing/constraining)

2. **Choose the filename prefix** based on the operation:
   - `add_` — adding a column or constraint to an existing table
   - `create_` — creating a new table
   - `drop_` — dropping a table (contract phase only)
   - `backfill_` — data migration to populate new columns
   - `remove_` — removing a column (contract phase only)

3. **Generate the migration file**:
   ```
   mix ecto.gen.migration <prefix>_<description>
   ```
   Example: `mix ecto.gen.migration add_reaction_emoji_to_messages`

4. **Open the generated file** and implement the migration. Apply the relevant rules below.

5. **Run the expand/contract checklist** (tick off each item before finishing):

### Expand phase checklist
- [ ] New columns are nullable OR have a default — never `null: false` without `default:`
- [ ] No existing columns renamed or dropped
- [ ] New indexes use `CREATE INDEX CONCURRENTLY` with `@disable_ddl_transaction true` and `@disable_migration_lock true`
- [ ] Raw SQL uses `execute/2` (reversible form) not `execute/1`

### Contract phase checklist
- [ ] Confirmed no running code references the column/table being removed
- [ ] `NOT NULL` constraints added only after backfilling all existing rows
- [ ] Dropping indexes that are no longer needed

6. **Verify reversibility**:
   ```
   mix ecto.migrate
   mix ecto.rollback
   mix ecto.migrate
   ```
   Both directions must succeed without errors.

7. **Never do these in a single migration** — the migration safety hook will warn, but stop and fix before proceeding:
   - Rename a column or table
   - Change a column type
   - Add `NOT NULL` without a default
   - Drop a column still referenced by running code

## Important

- Long-running data migrations (backfills) belong in a separate Mix task, not in the schema migration — schema migrations lock tables.
- If this migration touches a table with millions of rows, confirm the operation is safe (e.g., adding a nullable column is instant; adding a non-null column with a default rewrites every row in older Postgres versions).
- After writing the migration, remind the user to run `mix test` to confirm the schema change doesn't break existing tests.
