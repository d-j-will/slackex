defmodule Slackex.Encrypted do
  @moduledoc false
  use Boundary, deps: [], exports: [Binary, Map, HMAC]
end
