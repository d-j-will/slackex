Queue a feature spec for dark factory implementation.

## Usage

`/factory-queue <spec_path> <channel_name>`

Example: `/factory-queue docs/feature/bulk-import/ #factory`

## Steps

1. Validate the spec path exists: `ls {spec_path}`
2. Find the channel ID by searching for the channel name via MCP or the database
3. Call `queue_factory_run` MCP tool with `spec_path` and `channel_id`
4. Report: "Queued run {run_id} for {spec_path} in {channel_name}. Start the coordinator with /factory-coordinator to begin execution."

## Important

- The `:dark_factory` feature flag must be enabled
- The spec directory must exist and contain a readable spec
- The bot user must be subscribed to the target channel
