defmodule Slackex.Accounts.Guardian do
  @moduledoc """
  Guardian implementation for JWT encoding/decoding with user resource resolution.
  """

  use Guardian, otp_app: :slackex

  alias Slackex.Accounts

  @impl Guardian
  def subject_for_token(%Slackex.Accounts.User{id: id}, _claims) do
    {:ok, to_string(id)}
  end

  def subject_for_token(_, _) do
    {:error, :invalid_resource}
  end

  @impl Guardian
  def resource_from_claims(%{"sub" => id}) do
    case Integer.parse(id) do
      {int_id, ""} ->
        user = Accounts.get_user!(int_id)
        {:ok, user}

      _ ->
        {:error, :invalid_claims}
    end
  rescue
    Ecto.NoResultsError -> {:error, :resource_not_found}
  end

  def resource_from_claims(_) do
    {:error, :invalid_claims}
  end
end
