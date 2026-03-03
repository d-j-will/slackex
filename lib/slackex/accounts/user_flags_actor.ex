defimpl FunWithFlags.Actor, for: Slackex.Accounts.User do
  def id(%{id: id}), do: "user:#{id}"
end
