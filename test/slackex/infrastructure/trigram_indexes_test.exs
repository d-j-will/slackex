defmodule Slackex.Infrastructure.TrigramIndexesTest do
  use Slackex.DataCase, async: true

  @moduledoc """
  Verifies that the pg_trgm extension and GiST trigram indexes
  are present on the users table after migrations have run.
  """

  describe "trigram infrastructure" do
    test "pg_trgm extension is enabled" do
      result =
        Repo.query!("SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm'")

      assert length(result.rows) == 1
    end

    test "GiST trigram index exists on users.username" do
      result =
        Repo.query!(
          "SELECT indexname FROM pg_indexes WHERE tablename = 'users' AND indexname = 'users_username_trgm_idx'"
        )

      assert length(result.rows) == 1
    end

    test "GiST trigram index exists on users.display_name" do
      result =
        Repo.query!(
          "SELECT indexname FROM pg_indexes WHERE tablename = 'users' AND indexname = 'users_display_name_trgm_idx'"
        )

      assert length(result.rows) == 1
    end

    test "trigram indexes use GiST access method" do
      result =
        Repo.query!("""
        SELECT indexname, indexdef
        FROM pg_indexes
        WHERE tablename = 'users'
          AND indexname IN ('users_username_trgm_idx', 'users_display_name_trgm_idx')
        """)

      assert length(result.rows) == 2

      for [_name, indexdef] <- result.rows do
        assert indexdef =~ "USING gist"
        assert indexdef =~ "gist_trgm_ops"
      end
    end
  end
end
