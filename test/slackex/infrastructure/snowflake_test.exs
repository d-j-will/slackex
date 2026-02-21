defmodule Slackex.Infrastructure.SnowflakeTest do
  use ExUnit.Case, async: true

  import Bitwise
  alias Slackex.Infrastructure.Snowflake

  describe "generate/0" do
    test "generates unique IDs" do
      ids = Enum.map(1..1000, fn _ -> Snowflake.generate() end)
      assert length(Enum.uniq(ids)) == 1000
    end

    test "IDs are monotonically increasing" do
      ids = Enum.map(1..100, fn _ -> Snowflake.generate() end)
      assert ids == Enum.sort(ids)
    end

    test "IDs are positive 64-bit integers" do
      id = Snowflake.generate()
      assert is_integer(id)
      assert id > 0
      # Must fit in a signed 64-bit integer (used as bigint PK in Postgres)
      assert id < 1 <<< 63
    end
  end

  describe "extract_timestamp/1" do
    test "timestamp can be extracted from ID" do
      before_ms = :os.system_time(:millisecond)
      id = Snowflake.generate()
      after_ms = :os.system_time(:millisecond)

      extracted = Snowflake.extract_timestamp(id)

      assert extracted >= before_ms
      assert extracted <= after_ms
    end
  end
end
