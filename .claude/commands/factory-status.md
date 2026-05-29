Check the status of dark factory runs.

## Steps

1. Call `list_factory_runs` MCP tool (no status filter — returns all non-terminal runs)
2. Display each run in a table: run ID, spec path, status, attempt, branch name, last updated
3. If the user asks for "all" runs, call `list_factory_runs` with status "all" to include terminal states
4. If no runs found, report "No active factory runs."

## Status Meanings

| Status | Meaning |
|--------|---------|
| queued | Waiting for an agent to claim |
| implementing | Agent is working on it |
| awaiting_verification | Implementation done, waiting for Tier 2 |
| verifying_tier2 | Verification agent is checking |
| completed | Passed verification — ready for human review |
| needs_review | Failed or exhausted — needs human intervention |
| cancelled | Manually cancelled |
