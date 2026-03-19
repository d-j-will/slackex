Feature: Webhook Setup
  As Dave Williams, a solo developer running Slackex
  I want to create incoming webhooks for my channels
  So that external services like GitHub Actions can POST messages into Slackex

  Background:
    Given Dave is logged into Slackex as "dave.williams"

  # --- Step 1: Navigate to Webhook Management ---

  Scenario: View empty webhook list
    Given no webhooks have been created
    When Dave navigates to the Webhooks settings page
    Then Dave sees an explanation of incoming webhooks
    And Dave sees a "Create Webhook" button
    And the empty state suggests use cases like CI/CD and monitoring

  Scenario: View webhook list with existing webhooks
    Given a webhook "Deploy Bot" exists for channel "#deploys"
    And a webhook "Uptime Monitor" exists for channel "#alerts"
    When Dave navigates to the Webhooks settings page
    Then Dave sees 2 webhooks listed
    And each webhook shows its display name, target channel, and creation date
    And each webhook has options to manage or delete it

  # --- Step 2: Create Webhook ---

  Scenario: Create webhook for existing channel
    Given the channel "#deploys" exists
    When Dave clicks "Create Webhook"
    And Dave selects "#deploys" as the target channel
    And Dave enters "Deploy Bot" as the display name
    And Dave enters "GitHub Actions deploy notifications" as the description
    And Dave submits the form
    Then a webhook is created for channel "#deploys"
    And a bot user "Deploy Bot" is created with the is_bot flag set
    And the bot user is subscribed to "#deploys"
    And Dave sees the webhook confirmation page with the URL

  Scenario: Create webhook with auto-created channel
    Given no channel named "monitoring" exists
    When Dave clicks "Create Webhook"
    And Dave types "monitoring" as the channel name
    And Dave enters "Alert Bot" as the display name
    And Dave submits the form
    Then the "#monitoring" channel is created automatically
    And a webhook is created for "#monitoring"
    And the bot user "Alert Bot" is subscribed to "#monitoring"

  Scenario: Create webhook with default display name
    Given the channel "#general" exists
    When Dave clicks "Create Webhook"
    And Dave selects "#general" as the target channel
    And Dave leaves the display name empty
    And Dave submits the form
    Then a webhook is created with the default display name "Webhook"

  Scenario: Reject webhook with invalid channel name
    When Dave clicks "Create Webhook"
    And Dave types "My Invalid Channel!!!" as the channel name
    And Dave submits the form
    Then Dave sees a validation error "Channel names can only contain lowercase letters, numbers, and hyphens"
    And no webhook is created

  Scenario: Reject duplicate webhook name for same channel
    Given a webhook "Deploy Bot" already exists for channel "#deploys"
    When Dave creates another webhook named "Deploy Bot" for "#deploys"
    Then Dave sees an error "A webhook with this name already exists for #deploys"
    And no new webhook is created

  # --- Step 3: Copy Webhook URL ---

  Scenario: View and copy webhook URL after creation
    Given Dave has just created a webhook "Deploy Bot" for "#deploys"
    When the webhook confirmation page loads
    Then Dave sees the full webhook URL containing the embedded token
    And Dave sees a "Copy URL" button
    And Dave sees a curl example with the correct URL and JSON payload format
    And Dave sees a warning that the token cannot be viewed again after leaving this page
    And Dave sees documentation of the JSON payload format

  Scenario: Token not visible after leaving confirmation page
    Given Dave created a webhook "Deploy Bot" for "#deploys"
    And Dave has navigated away from the confirmation page
    When Dave returns to the Webhooks settings page
    Then Dave sees the "Deploy Bot" webhook listed
    But the webhook token is not displayed
    And Dave sees an option to regenerate the token

  # --- Webhook Management ---

  Scenario: Regenerate webhook token
    Given Dave has a webhook "Deploy Bot" for "#deploys"
    When Dave clicks "Regenerate Token" for the "Deploy Bot" webhook
    And Dave confirms the regeneration
    Then a new token is generated
    And the old token is invalidated immediately
    And Dave sees the new webhook URL (shown once)
    And Dave sees a warning to update external services with the new URL

  Scenario: Delete a webhook
    Given Dave has a webhook "Deploy Bot" for "#deploys"
    When Dave clicks "Delete" for the "Deploy Bot" webhook
    And Dave confirms the deletion
    Then the webhook is removed
    And the webhook token is invalidated
    And future POSTs to the old URL return 401
    And the bot user remains in the system but is no longer linked to a webhook
    And the "#deploys" channel and its messages are unaffected
