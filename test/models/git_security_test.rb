require "test_helper"

class GitSecurityTest < ActiveSupport::TestCase
  setup do
    Task.any_instance.stubs(:branches).returns([])
  end

  test "clone_repository does not expose token in repository URL" do
    task = tasks(:without_runs)
    user = task.user
    user.update!(github_token: "secret_token_123")

    project = task.project
    project.update!(repository_url: "https://github.com/user/repo.git")

    run = task.runs.create!(prompt: "test")

    Docker::Container.expects(:create).with do |config|
      assert_equal "https://github.com/user/repo.git", project.repository_url
      assert_match(/git clone https:\/\/github.com\/user\/repo.git/, config["Cmd"][1])
      refute_match(/secret_token_123/, config["Cmd"][1])
      assert_includes config["Env"], "GITHUB_TOKEN=secret_token_123"
      assert_includes config["Env"], "GIT_ASKPASS=/tmp/git-askpass.sh"
      true
    end.returns(mock_container)

    run.send(:clone_repository)
  end

  test "push_changes_to_branch does not expose token in remote URL" do
    task = tasks(:without_runs)
    user = task.user
    user.update!(github_token: "secret_token_123")

    project = task.project
    project.update!(repository_url: "https://github.com/user/repo.git")

    # Enable auto push
    task.update!(auto_push_enabled: true, auto_push_branch: "main")

    # Ensure volume mounts exist
    task.workplace_mount

    Docker::Container.expects(:create).with do |config|
      cmd = config["Cmd"][1]
      assert_match(/git remote set-url origin 'https:\/\/github.com\/user\/repo.git'/, cmd)
      refute_match(/secret_token_123/, cmd)
      assert_includes config["Env"], "GITHUB_TOKEN=secret_token_123"
      assert_includes config["Env"], "GIT_ASKPASS=/tmp/git-askpass.sh"
      true
    end.returns(mock_container)

    task.push_changes_to_branch
  end

  test "SSH URLs are preserved exactly as provided" do
    task = tasks(:without_runs)
    user = task.user
    user.update!(ssh_key: "ssh-rsa AAAAB3NzaC1...")

    agent = task.agent
    agent.update!(ssh_mount_path: "/home/user/.ssh/id_rsa")

    project = task.project
    project.update!(repository_url: "git@github.com:JoeDupuis/shenanigans.git")

    run = task.runs.create!(prompt: "test")

    Docker::Container.expects(:create).with do |config|
      cmd = config["Cmd"][1]
      assert_match(/git clone git@github\.com:JoeDupuis\/shenanigans\.git/, cmd)
      refute_match(/ssh-rsa/, cmd)
      true
    end.returns(mock_container)

    run.send(:clone_repository)
  end

  test "SSH key is not exposed in git commands" do
    task = tasks(:without_runs)
    user = task.user
    ssh_key = "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret_ssh_key_content\n-----END OPENSSH PRIVATE KEY-----"
    user.update!(ssh_key: ssh_key)

    agent = task.agent
    agent.update!(ssh_mount_path: "/home/user/.ssh/id_rsa")

    project = task.project
    project.update!(repository_url: "git@github.com:JoeDupuis/shenanigans.git")

    task.update!(auto_push_enabled: true, auto_push_branch: "main")
    task.workplace_mount

    Docker::Container.expects(:create).with do |config|
      cmd = config["Cmd"][1]
      refute_match(/secret_ssh_key_content/, cmd)
      refute_match(/BEGIN OPENSSH PRIVATE KEY/, cmd)
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
