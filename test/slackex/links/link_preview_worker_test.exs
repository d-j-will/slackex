defmodule Slackex.Links.LinkPreviewWorkerTest do
  use Slackex.DataCase, async: false
  use Oban.Testing, repo: Slackex.Repo

  alias Slackex.Links.LinkPreview
  alias Slackex.Links.LinkPreviewWorker

  describe "enqueue/2" do
    test "inserts an Oban job with message_id and urls" do
      assert {:ok, %Oban.Job{}} =
               LinkPreviewWorker.enqueue(123, ["https://example.com"])
    end

    test "returns :noop when urls list is empty" do
      assert :noop = LinkPreviewWorker.enqueue(123, [])
    end
  end

  describe "perform/1 with blocked domain" do
    test "creates a blocked link_preview record" do
      assert :ok =
               perform_job(LinkPreviewWorker, %{
                 "message_id" => 999,
                 "urls" => ["https://pornhub.com/video"]
               })

      preview = Repo.get_by!(LinkPreview, message_id: 999)
      assert preview.status == "blocked"
      assert preview.blocked_reason == "blocklist"
    end
  end

  describe "perform/1 with unreachable URL" do
    test "creates a blocked link_preview record for connection error" do
      assert :ok =
               perform_job(LinkPreviewWorker, %{
                 "message_id" => 998,
                 "urls" => ["https://this-domain-definitely-does-not-exist-abc123.com"]
               })

      preview = Repo.get_by!(LinkPreview, message_id: 998)
      assert preview.status == "blocked"
      assert preview.blocked_reason == "fetch_error"
    end
  end
end
