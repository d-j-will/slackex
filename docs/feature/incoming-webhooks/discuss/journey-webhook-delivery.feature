Feature: Webhook Delivery
  As an external service (e.g., GitHub Actions)
  I want to POST messages to a Slackex webhook URL
  So that notifications appear in the configured channel in real-time

  Background:
    Given a webhook "Deploy Bot" exists for channel "#deploys" with token "whk_a1b2c3d4e5f6"
    And the bot user "Deploy Bot" has is_bot set to true

  # --- Step 1: Receive and Validate POST ---

  Scenario: Successful message delivery
    When GitHub Actions POSTs to /api/webhooks/whk_a1b2c3d4e5f6 with:
      | text | **Deployed: v0.5.80**\n\n**Repo:** davewil/slackex |
    Then the response status is 200
    And the response body is {"ok": true}
    And a message appears in "#deploys" from "Deploy Bot"

  Scenario: Delivery with username override
    When GitHub Actions POSTs to /api/webhooks/whk_a1b2c3d4e5f6 with:
      | text     | Build failed on master               |
      | username | CI Bot                               |
    Then the response status is 200
    And the message in "#deploys" shows sender name "CI Bot" instead of "Deploy Bot"

  Scenario: Invalid token returns 401
    When an external service POSTs to /api/webhooks/whk_completely_invalid with:
      | text | Hello |
    Then the response status is 401
    And the response body contains "invalid_token"
    And no message is created

  Scenario: Revoked webhook returns 401
    Given the webhook "Deploy Bot" has been deleted
    When GitHub Actions POSTs to /api/webhooks/whk_a1b2c3d4e5f6 with:
      | text | Deploy complete |
    Then the response status is 401
    And the response body contains "invalid_token"

  Scenario: Missing text field returns 400
    When GitHub Actions POSTs to /api/webhooks/whk_a1b2c3d4e5f6 with:
      | username | Deploy Bot |
    Then the response status is 400
    And the response body contains "missing_text_field"
    And no message is created

  Scenario: Empty text field returns 400
    When GitHub Actions POSTs to /api/webhooks/whk_a1b2c3d4e5f6 with:
      | text | |
    Then the response status is 400
    And the response body contains "missing_text_field"

  Scenario: Malformed JSON returns 400
    When an external service POSTs "this is not json" to /api/webhooks/whk_a1b2c3d4e5f6
    Then the response status is 400
    And the response body contains "invalid_json"

  Scenario: Oversized payload returns 413
    When GitHub Actions POSTs a 20KB JSON body to /api/webhooks/whk_a1b2c3d4e5f6
    Then the response status is 413
    And the response body contains "payload_too_large"

  Scenario: Rate-limited request returns 429
    Given the webhook "whk_a1b2c3d4e5f6" has received 60 requests in the last minute
    When GitHub Actions POSTs to /api/webhooks/whk_a1b2c3d4e5f6 with:
      | text | Another deploy |
    Then the response status is 429
    And the response body contains "rate_limited"
    And the response includes a "Retry-After" header

  # --- Step 2: Message Creation ---

  Scenario: Message persisted with encryption
    When GitHub Actions POSTs to /api/webhooks/whk_a1b2c3d4e5f6 with:
      | text | Deploy v0.5.80 to production |
    Then a message is inserted into the messages table
    And the message content is encrypted via Cloak
    And the message search_content contains "Deploy v0.5.80 to production" in plaintext
    And the message sender_id matches the "Deploy Bot" bot user
    And the message channel_id matches the "#deploys" channel
    And the message has a valid Snowflake ID

  Scenario: Message broadcast via PubSub
    Given Dave is subscribed to the "#deploys" channel PubSub topic
    When GitHub Actions POSTs a message to /api/webhooks/whk_a1b2c3d4e5f6
    Then a PubSub envelope with event "message.new" is broadcast on "channel:{deploys_id}"
    And the envelope payload includes the message content and bot user info

  # --- Step 3: Real-Time Display ---

  Scenario: Bot message appears with BOT badge
    Given Dave has the "#deploys" channel open in Slackex
    When a webhook delivers the message "**Deployed: v0.5.80**" to "#deploys"
    Then Dave sees a new message from "Deploy Bot" with a "[BOT]" badge
    And the message content "Deployed: v0.5.80" is rendered in bold (markdown)

  Scenario: Bot message with clickable links
    Given Dave has the "#deploys" channel open in Slackex
    When a webhook delivers a message containing "[View logs](https://github.com/davewil/slackex/actions/runs/12345)"
    Then Dave sees "View logs" rendered as a clickable link
    And the link opens https://github.com/davewil/slackex/actions/runs/12345

  Scenario: Bot message searchable via full-text search
    Given a webhook has delivered the message "Deployed v0.5.80 to production" to "#deploys"
    When Dave searches for "v0.5.80" in Slackex
    Then the webhook message appears in search results
    And the result shows it was sent by "Deploy Bot" with the BOT badge
