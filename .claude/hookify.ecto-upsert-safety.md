---
name: warn-ecto-upsert-safety
enabled: true
event: file
conditions:
  - field: file_path
    operator: regex_match
    pattern: \.ex$
  - field: new_text
    operator: contains
    pattern: "on_conflict: :nothing"
  - field: new_text
    operator: not_contains
    pattern: "id: nil"
---

**Ecto upsert safety warning: `on_conflict: :nothing` without nil-id handling detected.**

When a conflict occurs, `Repo.insert(changeset, on_conflict: :nothing)` returns `{:ok, %Struct{id: nil}}` — a ghost struct with no database identity. Downstream code using `nil` id hits FK constraint violations.

**Required pattern:**
```elixir
case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [...]) do
  {:ok, %MySchema{id: nil}} ->
    # Conflict: re-fetch the existing record
    {:ok, Repo.get_by!(MySchema, unique_field: value)}
  other ->
    other
end
```

See CLAUDE.md "Ecto upsert safety" section for full details.
