Feature: Independent Verification
  As a human operator
  I want a separate agent to independently verify implementations against the spec
  So I have confidence beyond the implementing agent's own interpretation

  Background:
    Given the dark factory feature flag is enabled
    And a coordinator agent session is running
    And a run has been successfully implemented and is "awaiting_verification"

  # --- Job H: Independent Verification ---

  Scenario: Full verification pass
    Given run-42 is in "awaiting_verification" with branch "factory/run-42"
    When the coordinator claims verification work
    Then the run transitions to "verifying_tier2"
    And the thread shows "Verification started"
    When the verification agent reads the spec at the pinned commit SHA
    And generates 5 unseen scenarios from the spec alone
    And checks out the feature branch
    And all 5 scenarios pass
    Then the coordinator submits verification with passed: true
    And the run transitions to "completed"
    And the thread shows "Tier 2 passed (5/5) — ready for review"

  Scenario: Verification failure
    Given run-42 is in "awaiting_verification" with branch "factory/run-42"
    When the verification agent runs 5 scenarios and 2 fail
    Then the coordinator submits verification with passed: false
    And the run transitions to "needs_review"
    And the thread shows "Tier 2 failed (3/5) — needs review"
    And the tier2_result includes failure details
    And the verification branch "factory/verify-run-42" is pushed as an artifact

  Scenario: Verification never auto-retries
    Given run-42 failed Tier 2 verification
    Then the run is in "needs_review" status
    And the run is NOT automatically re-queued
    And human intervention is required to decide next steps

  # --- Isolation guarantees ---

  Scenario: Verification agent reads spec before implementation
    Given the verification agent is spawned for run-42
    When the agent begins work
    Then it reads the spec at "docs/feature/bulk-import/" first
    And it reads CLAUDE.md and engineering principles
    And it reads docs/rca/ for project-specific failure modes
    And it generates scenarios BEFORE looking at any implementation code

  Scenario: Verification agent never sees implementation context
    Given the verification agent is working on run-42
    Then it does NOT have access to:
      | Artifact                              |
      | Implementing agent's conversation     |
      | Implementing agent's plan             |
      | Tier 1 test results                   |
      | Progress messages from impl thread    |
      | Implementation reasoning or decisions |

  Scenario: Scenarios cover project-specific antipatterns
    Given the verification agent reads docs/rca/ and CLAUDE.md
    When it generates scenarios
    Then the scenarios include checks for:
      | Antipattern                  | Source                        |
      | nil-id ghost structs         | Ecto upsert safety (CLAUDE.md)|
      | swallowed Oban errors        | v0.5.36 RCA                   |
      | missing PubSub wiring        | v0.5.47-v0.5.64 RCA           |
      | partition key omissions      | Project conventions            |
      | supervisor cascade risk      | OTP resilience principles      |

  Scenario: Verification branch pushed as artifact
    Given the verification agent has completed all scenarios
    When it pushes branch "factory/verify-run-42"
    Then the branch contains the scenario test files
    And the human can review both the implementation and verification branches

  # --- Timeout ---

  Scenario: Verification claim released on timeout
    Given a verification agent claimed run-42
    And the coordinator crashes during verification
    When the heartbeat timeout expires
    Then the LifecycleWorker transitions run-42 to "awaiting_verification"
    And the claim is released for another verification agent to pick up

  # --- Concurrent verification ---

  Scenario: Verification runs alongside new implementations
    Given run-42 is being verified
    And run-57 is queued for implementation
    When the coordinator has concurrency capacity
    Then it can claim and start implementing run-57
    While run-42 verification continues in parallel
