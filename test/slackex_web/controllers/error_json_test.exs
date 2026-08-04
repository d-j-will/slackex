defmodule SlackexWeb.ErrorJSONTest do
  use SlackexWeb.ConnCase, async: true

  # The stock generator tests asserted that 404 renders "Not Found" and 500
  # renders "Internal Server Error". Those strings come from
  # Phoenix.Controller.status_message_from_template/1 -- nobody here chose that
  # wording, and no change to this repo could alter it.
  #
  # What is ours is the envelope: every JSON error is wrapped as
  # %{errors: %{detail: _}}, which is what API and relay clients parse. That
  # shape is asserted below without borrowing Phoenix's status table, and for an
  # unremarkable template as well as the famous two, so the test pins the
  # wrapper rather than a pair of special cases.
  #
  # The companion error_html_test.exs was deleted rather than reshaped:
  # SlackexWeb.ErrorHTML delegates its whole body to Phoenix and adds nothing,
  # so there was no fact of ours left to assert.

  test "every rendered error is wrapped in the errors/detail envelope" do
    for template <- ["404.json", "500.json", "422.json"] do
      assert %{errors: %{detail: detail}} = SlackexWeb.ErrorJSON.render(template, %{})

      assert is_binary(detail) and detail != "",
             "#{template} produced an empty detail; clients render this string"
    end
  end
end
