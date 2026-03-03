defmodule Slackex.Infrastructure do
  @moduledoc false
  use Boundary, deps: [], exports: [Snowflake, RateLimiter]
end
