Feature: Factory Execution
  As a human operator
  I want the coordinator to manage factory runs autonomously
  So I can queue specs and walk away while work gets done

  Background:
    Given the dark factory feature flag is enabled
    And a coordinator agent session is running
    And a bot user exists with MCP credentials

  # --- Job A: Unattended Execution ---

  Scenario: Full pipeline - queue to completed
    Given I have written a spec at "docs/feature/bulk-import/"
    And a channel "#factory" exists for status updates
    When I queue a factory run with spec_path "docs/feature/bulk-import/" and channel "#factory"
    Then a run is created in "queued" status
    And a thread message is posted to "#factory"
    When the coordinator polls for available work
    Then the run appears in the work list
    When the coordinator claims the run
    Then the run transitions to "implementing"
    And a "claimed" message is posted to the thread
    And a worktree agent is spawned at ".factory/run-{id}/"
    When the implementing agent completes successfully
    And pushes branch "factory/run-{id}"
    And the coordinator submits success
    Then the run transitions to "awaiting_verification"
    When the verification agent claims and passes all scenarios
    Then the run transitions to "completed"
    And the thread shows "Tier 2 passed — ready for review"

  Scenario: Implementation failure with retry
    Given a run is in "implementing" status with attempt 1 of 3
    When the implementing agent submits failure with summary "test failures"
    Then the run stays in "implementing" with attempt 2
    And an event is logged: "Attempt 1 failed, retrying (2/3)"

  Scenario: Implementation failure exhausted
    Given a run is in "implementing" status with attempt 3 of 3
    When the implementing agent submits failure
    Then the run transitions to "needs_review"
    And the thread shows "All 3 attempts exhausted — needs human review"

  # --- Job G: Protocol Abstraction ---

  Scenario: Coordinator handles full MCP protocol transparently
    Given a spec is queued
    When the coordinator session is running
    Then the coordinator automatically calls list_factory_work
    And automatically calls claim_factory_work with the current commit SHA
    And automatically heartbeats every 5 minutes
    And automatically calls submit_factory_result when the agent finishes
    And the human never directly calls any factory MCP tool

  # --- Job C: Concurrent Throughput ---

  Scenario: Concurrent execution up to limit
    Given 3 runs are queued
    And the concurrency limit is 2
    When the coordinator polls for work
    Then it claims and spawns agents for 2 runs
    And the 3rd run remains queued
    When one agent completes
    Then the coordinator claims the 3rd run on the next poll

  Scenario: Concurrency limit respected under load
    Given 5 runs are queued
    And the concurrency limit is 2
    When the coordinator polls for work
    Then only 2 agents are running simultaneously
    And 3 runs remain queued

  # --- Job D: Ambient Awareness ---

  Scenario: Structured progress updates in thread
    Given a run is in "implementing" status
    When the coordinator heartbeats with message "Implementing step 3/7: CSV parser module"
    Then the thread shows "[Factory: bulk-import] Implementing step 3/7: CSV parser module"

  # --- Job E: Crash Resilience ---

  Scenario: Coordinator crash releases stale claims
    Given a run is in "implementing" status
    And the coordinator has crashed
    When the last heartbeat exceeds the timeout
    Then the LifecycleWorker transitions the run to "queued"
    And the claim_token is cleared
    And the attempt count is preserved

  Scenario: Coordinator restart discovers orphaned worktrees
    Given the coordinator was previously running with run-42 active
    And the coordinator crashed and was restarted
    When the coordinator discovers ".factory/run-42/" worktree
    And run-42 is in "queued" status (released by timeout)
    Then the coordinator re-claims run-42
    And reuses the existing worktree

  Scenario: Cancel by owner
    Given a run is in "queued" status owned by my bot user
    When I cancel the run
    Then the run transitions to "cancelled"
    And the thread shows "Run cancelled"

  Scenario: Cannot cancel terminal run
    Given a run is in "completed" status
    When I attempt to cancel the run
    Then the operation fails with "already_terminal"
