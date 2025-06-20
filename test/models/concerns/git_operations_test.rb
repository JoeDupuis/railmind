require "test_helper"

class GitOperationsTest < ActiveSupport::TestCase
  setup do
    Task.any_instance.stubs(:branches).returns([])
  end

  test "clone_repository uses git credentials for GitHub URLs" do
    task = tasks(:without_runs)
    user = task.user
    user.update!(github_token: "test_token_123")

    project = task.project
    project.update!(repository_url: "https://github.com/test/repo.git")

    run = task.runs.create!(prompt: "test")

    Docker::Container.expects(:create).with do |config|
      assert_includes config["Env"], "GITHUB_TOKEN=test_token_123"
      assert_includes config["Env"], "GIT_ASKPASS=/tmp/git-askpass.sh"
      assert_match(/git clone https:\/\/github.com\/test\/repo.git/, config["Cmd"][1])
      true
    end.returns(mock_container)

    run.clone_repository
  end

  test "push_changes_to_branch uses git credentials for GitHub URLs" do
    task = tasks(:without_runs)
    user = task.user
    user.update!(github_token: "test_token_123")

    project = task.project
    project.update!(repository_url: "https://github.com/test/repo.git")
    task.update!(auto_push_enabled: true, auto_push_branch: "main")
    task.workplace_mount

    Docker::Container.expects(:create).with do |config|
      assert_includes config["Env"], "GITHUB_TOKEN=test_token_123"
      assert_includes config["Env"], "GIT_ASKPASS=/tmp/git-askpass.sh"
      true
    end.returns(mock_container)

    task.push_changes_to_branch
  end

  test "git operations do not use credentials for non-GitHub URLs" do
    task = tasks(:without_runs)
    user = task.user
    user.update!(github_token: "test_token_123")

    project = task.project
    project.update!(repository_url: "https://gitlab.com/test/repo.git")

    run = task.runs.create!(prompt: "test")

    Docker::Container.expects(:create).with do |config|
      env = config["Env"] || []
      refute_includes env, "GITHUB_TOKEN=test_token_123"
      refute_includes env, "GIT_ASKPASS=/tmp/git-askpass.sh"
      true
    end.returns(mock_container)

    run.clone_repository
  end

  test "clone_repository works with SSH URLs" do
    task = tasks(:without_runs)
    user = task.user
    user.update!(ssh_key: "ssh-rsa AAAAB3NzaC1...")

    agent = task.agent
    agent.update!(ssh_mount_path: "/home/user/.ssh/id_rsa")

    project = task.project
    project.update!(repository_url: "git@github.com:JoeDupuis/shenanigans.git")

    run = task.runs.create!(prompt: "test")

    Docker::Container.expects(:create).with do |config|
      assert_equal "git clone git@github.com:JoeDupuis/shenanigans.git .", config["Cmd"][1]
      env = config["Env"] || []
      refute_includes env, "GITHUB_TOKEN="
      refute_includes env, "GIT_ASKPASS=/tmp/git-askpass.sh"
      true
    end.returns(mock_container)

    run.clone_repository
  end

  test "push_changes_to_branch works with SSH URLs" do
    task = tasks(:without_runs)
    user = task.user
    user.update!(ssh_key: "ssh-rsa AAAAB3NzaC1...")

    agent = task.agent
    agent.update!(ssh_mount_path: "/home/user/.ssh/id_rsa")

    project = task.project
    project.update!(repository_url: "git@github.com:JoeDupuis/shenanigans.git")
    task.update!(auto_push_enabled: true, auto_push_branch: "main")
    task.workplace_mount

    Docker::Container.expects(:create).with do |config|
      assert_match(/git remote set-url origin 'git@github\.com:JoeDupuis\/shenanigans\.git'/, config["Cmd"][1])
      assert_match(/git push/, config["Cmd"][1])
      env = config["Env"] || []
      refute_includes env, "GITHUB_TOKEN="
      refute_includes env, "GIT_ASKPASS=/tmp/git-askpass.sh"
      true
    end.returns(mock_container)

    task.push_changes_to_branch
  end

  private

  def mock_container
    container = mock("container")
    container.expects(:start)
    container.expects(:exec).with(anything).at_least(0).at_most(4)
    container.expects(:wait).returns({ "StatusCode" => 0 })
    container.expects(:logs).returns("Success")
    container.expects(:delete)
    container
  end
end
