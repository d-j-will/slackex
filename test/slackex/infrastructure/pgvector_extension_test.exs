defmodule Slackex.Infrastructure.PgvectorExtensionTest do
  use Slackex.DataCase, async: true

  @moduledoc """
  Verifies that the pgvector extension is enabled and functional
  after migrations have run.
  """

  describe "pgvector extension" do
    test "vector extension is enabled" do
      result =
        Repo.query!("SELECT 1 FROM pg_extension WHERE extname = 'vector'")

      assert length(result.rows) == 1
    end

    test "vector_dims function returns correct dimensions" do
      result =
        Repo.query!("SELECT vector_dims('[1,2,3]'::vector)")

      assert result.rows == [[3]]
    end
  end
end
