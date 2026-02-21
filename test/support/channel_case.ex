defmodule SlackexWeb.ChannelCase do
  @moduledoc """
  Test case template for Phoenix channel tests.
  Sets up the Ecto sandbox and imports Phoenix.ChannelTest helpers.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import Slackex.Factory

      @endpoint SlackexWeb.Endpoint
    end
  end

  setup tags do
    Slackex.DataCase.setup_sandbox(tags)
    :ok
  end
end
