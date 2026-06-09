defmodule Mix.Tasks.GitHooks.Install do
  use Boundary, classify_to: Slackex.MixTasks
  @moduledoc "Installs git hooks from priv/git_hooks/ into .git/hooks/"
  @shortdoc "Install git hooks"

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    source_dir = Path.join(["priv", "git_hooks"])
    target_dir = Path.join([".git", "hooks"])

    if File.dir?(source_dir) and File.dir?(target_dir) do
      source_dir
      |> File.ls!()
      |> Enum.each(fn hook ->
        source = Path.join(source_dir, hook)
        target = Path.join(target_dir, hook)
        File.cp!(source, target)
        File.chmod!(target, 0o755)
        Mix.shell().info("Installed git hook: #{hook}")
      end)
    else
      Mix.shell().info("Skipping git hooks (not a git repository or no hooks found)")
    end
  end
end
