#!/bin/bash
docker cp /root/slackex/mcp-join-channels.exs slackex-app-1:/tmp/
docker exec slackex-app-1 bin/slackex rpc 'Code.eval_file("/tmp/mcp-join-channels.exs")'
