defmodule Slackex.Infrastructure do
  use Boundary, deps: [], exports: [Snowflake, RateLimiter]
end
