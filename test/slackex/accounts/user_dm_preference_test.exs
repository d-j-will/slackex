defmodule Slackex.Accounts.UserDmPreferenceTest do
  use Slackex.DataCase, async: true

  alias Slackex.Accounts.User

  describe "dm_preference field on users" do
    test "new user gets default dm_preference of 'anyone'" do
      user = insert(:user)
      user = Repo.get!(User, user.id)
      assert user.dm_preference == "anyone"
    end

    test "dm_preference can be updated to each allowed value" do
      user = insert(:user)

      for value <- ["anyone", "shared_channels", "nobody"] do
        changeset = User.dm_preference_changeset(user, %{dm_preference: value})
        assert changeset.valid?, "expected changeset to be valid for value: #{value}"
        {:ok, updated} = Repo.update(changeset)
        assert updated.dm_preference == value
      end
    end

    test "dm_preference rejects invalid values" do
      user = insert(:user)
      changeset = User.dm_preference_changeset(user, %{dm_preference: "everyone"})
      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:dm_preference]
    end
  end
end
