defmodule Slackex.MixTasks do
  @moduledoc """
  Classification target for this app's Mix tasks (`use Boundary, classify_to:
  Slackex.MixTasks` in each task). Tasks are operator tooling that may reach
  into any context, so checks are deliberately off for this boundary.
  """

  use Boundary, check: [in: false, out: false]
end
