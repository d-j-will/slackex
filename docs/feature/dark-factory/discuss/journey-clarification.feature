Feature: Clarification Threading
  As a human operator
  I want implementing agents to ask targeted questions when specs are ambiguous
  So I don't waste implementation cycles on wrong assumptions

  Background:
    Given the dark factory feature flag is enabled
    And a coordinator agent session is running
    And a run is in "implementing" status in channel "#factory"

  # --- Job B: Clarification Over Guessing ---

  Scenario: Agent asks clarification for high-stakes ambiguity
    Given the implementing agent encounters an ambiguity in acceptance-criteria item 3
    And the wrong guess would change more than one test case
    When the agent requests clarification
    Then the coordinator posts to the run's thread:
      """
      [CLARIFY:run-42:spec:acceptance-criteria:3]
      The spec says "messages are delivered in order" but doesn't define
      ordering for concurrent senders. Per-channel (Snowflake) or per-sender?
      """
    And the agent is marked as "clarifying" in coordinator state
    And the coordinator continues heartbeating for this run

  Scenario: Agent assumes for low-stakes ambiguity
    Given the implementing agent encounters a minor ambiguity
    And the wrong guess would affect at most one test case
    When the agent assesses confidence
    Then the agent makes a judgment call
    And documents the assumption in the PR description
    And continues implementing without asking

  Scenario: Human responds to clarification
    Given a clarification was posted to the thread for "acceptance-criteria:3"
    When the human replies with "Per-channel ordering via Snowflake ID"
    Then the coordinator detects the reply in the thread
    And forwards the answer to the waiting agent
    And the agent resumes implementation
    And the thread shows "Clarification received, resuming"

  Scenario: Clarification timeout - agent assumes
    Given a clarification was posted to the thread
    And 2 hours have passed with no human response
    When the clarification times out
    Then the coordinator posts a timeout notice to the thread
    And the agent makes a reasonable assumption
    And documents the assumption prominently in the PR description
    And continues implementing

  Scenario: Clarification timeout - agent fails on fundamental ambiguity
    Given a clarification was posted about a fundamental design question
    And 2 hours have passed with no human response
    When the clarification times out
    And the agent determines the ambiguity is too fundamental to assume
    Then the agent submits failure with reason "blocked on clarification"

  Scenario: Multiple clarifications in one run
    Given the implementing agent has asked 2 clarification questions
    And question 1 "acceptance-criteria:3" has been answered
    And question 2 "data-model:users:soft-delete" is still pending
    When the agent receives the answer to question 1
    Then it can continue implementing parts unrelated to question 2
    And question 2 remains in "pending" status

  Scenario: Other agents unaffected by clarification wait
    Given agent-1 is waiting for clarification on run-42
    And agent-2 is implementing run-57
    When agent-1 is in "clarifying" state
    Then agent-2 continues implementing normally
    And the coordinator continues heartbeating for both runs

  # --- Job F: Spec Refinement Through Use ---

  Scenario: Spec amendments proposed after run completes
    Given run-42 had 2 clarification Q&A exchanges during implementation
    When run-42 reaches a terminal state
    Then the coordinator collects all [CLARIFY:...] Q&A pairs
    And posts proposed spec amendments to the thread:
      """
      [SPEC-AMENDMENT:run-42]
      Based on clarification Q&A during this run:

      1. Section: acceptance-criteria, item 3
         Original: "Messages are delivered in order"
         Proposed: "Messages are delivered in per-channel order (Snowflake ID).
         Per-sender ordering is not guaranteed for concurrent senders."

      2. Section: data-model, users, soft-delete
         Original: (not specified)
         Proposed: "Users are soft-deleted. All queries filter by deleted_at IS NULL."

      Approve these amendments? Reply "approve all" or specify which to accept.
      """

  Scenario: Human approves spec amendments
    Given spec amendments were proposed for run-42
    When the human replies "approve all"
    Then the spec at "docs/feature/bulk-import/" is updated with the amendments
    And future runs against this spec won't encounter the same ambiguities

  Scenario: Human rejects spec amendments
    Given spec amendments were proposed for run-42
    When the human replies "reject 2" (keeping amendment 1)
    Then only amendment 1 is applied to the spec
    And amendment 2 is discarded
