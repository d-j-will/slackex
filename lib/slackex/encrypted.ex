defmodule Slackex.Encrypted do
  use Boundary, deps: [], exports: [Binary, Map, HMAC]
end
