defmodule Slackex.Repo.Migrations.CreateFunWithFlagsToggles do
  use Ecto.Migration

  def change do
    create table(:fun_with_flags_toggles) do
      add :flag_name, :string, null: false
      add :gate_type, :string, null: false
      add :target, :string, null: false
      add :enabled, :boolean, null: false
    end

    create unique_index(:fun_with_flags_toggles, [:flag_name, :gate_type, :target])
  end
end
