require "test_helper"

class RunTest < ActiveSupport::TestCase
  setup do
    Task.any_instance.stubs(:branches).returns([])
  end
  # Docker prefixes logs with 8 bytes of metadata
  DOCKER_LOG_HEADER = "\x01\x00\x00\x00\x00\x00\x00"

  test "should identify first run correctly" do
    task = tasks(:without_runs)

    first_run = task.runs.create!(prompt: "first")
    assert first_run.first_run?

    second_run = task.runs.create!(prompt: "second")
    assert_not second_run.first_run?
  end

  test "execute! includes project secrets in container environment variables" do
    task = tasks(:without_runs)
    project = task.project
    project.secrets.create!(key: "API_KEY", value: "secret_123")
    project.secrets.create!(key: "DB_PASSWORD", value: "db_pass_456")

    run = task.runs.create!(prompt: "test command", status: :pending)

    expect_clone_and_branch_detection(clone_cmd: "git clone 'http://example.com/one.git' '.'", env: [ "API_KEY=secret_123", "DB_PASSWORD=db_pass_456" ], binds: instance_of(Array))
    expect_main_container(
      cmd: [ "echo", "STARTING: test command" ],
      output: "\x0bhello world",
      env: [ "API_KEY=secret_123", "DB_PASSWORD=db_pass_456" ]
    )
    expect_git_diff_container
    expect_broadcast_refresh

    run.execute!

    assert run.completed?
  end

  test "execute! combines project secrets with agent environment variables" do
    task = tasks(:with_env_vars)
    project = task.project
    project.secrets.create!(key: "API_KEY", value: "secret_123")

    run = task.runs.create!(prompt: "test command", status: :pending)

    expect_clone_and_branch_detection(clone_cmd: "git clone 'http://example.com/one.git' '.'", env: [ "NODE_ENV=development", "DEBUG=true", "API_KEY=secret_123" ], binds: instance_of(Array))
    expect_main_container(
      cmd: [ "echo", "test command" ],
      output: "\x0bhello world",
      env: [ "NODE_ENV=development", "DEBUG=true", "API_KEY=secret_123" ]
    )
    expect_git_diff_container
    expect_broadcast_refresh

    run.execute!

    assert run.completed?
  end

  test "execute! handles errors gracefully" do
    run = runs(:pending)
    Docker::Container.expects(:create).raises(Docker::Error::NotFoundError, "Image not found")

    assert_nothing_raised { run.execute! }
    assert run.failed?
    assert_not_nil run.started_at
    assert_not_nil run.completed_at
    assert_equal 1, run.steps.count
    assert_includes run.steps.first.raw_response, "Error:"
    assert_includes run.steps.first.raw_response, "Image not found"
  end

  test "execute! calls Docker container methods correctly for first run" do
    task = tasks(:without_runs)
    run = task.runs.create!(prompt: "test command", status: :pending)

    expect_clone_and_branch_detection(clone_cmd: "git clone 'http://example.com/one.git' '.'", binds: instance_of(Array))
    expect_main_container(
      cmd: [ "echo", "STARTING: test command" ],
      output: "\x0bhello world"
    )
    expect_git_diff_container


    run.execute!

    assert run.completed?
    assert_equal 3, run.steps.count
    assert_equal "hello world", run.steps.first.raw_response
    assert run.steps.last.content.start_with?("Repository state captured")
  end

  test "execute! uses continue_arguments for subsequent runs" do
    task = tasks(:task_with_runs)
    run = task.runs.last
    run.update!(status: :pending, started_at: nil, completed_at: nil)
    run.steps.destroy_all

    expect_main_container(
      cmd: [ "echo hello" ],
      output: "\x10continued output"
    )
    expect_git_diff_container

    run.execute!

    assert run.completed?
    assert_equal 3, run.steps.count
    assert_equal "continued output", run.steps.first.raw_response
  end

  test "execute! configures Docker host when specified and resets after completion" do
    original_url = Docker.url

    task = tasks(:with_docker_host)
    run = task.runs.create!(prompt: "test", status: :pending)

    Docker.expects(:url=).with("tcp://192.168.1.100:2375").once
    Docker.expects(:url=).with(original_url).once

    expect_main_container(cmd: [ "echo", "test" ], output: "\x04test")

    run.execute!

    assert run.completed?
    assert_equal original_url, Docker.url
  end

  test "execute! resets Docker host even when run fails" do
    original_url = "unix:///var/run/docker.sock"
    Docker.url = original_url

    task = tasks(:with_docker_host)
    run = task.runs.create!(prompt: "test", status: :pending)

    # Mock Docker to fail
    Docker::Container.expects(:create).raises(Docker::Error::NotFoundError, "Image not found")

    run.execute!

    assert run.failed?
    assert_equal original_url, Docker.url
  end



  test "execute! passes environment variables to Docker container" do
    task = tasks(:with_env_vars)
    run = task.runs.create!(prompt: "test", status: :pending)

    expect_clone_and_branch_detection(clone_cmd: "git clone 'http://example.com/one.git' '.'", env: [ "NODE_ENV=development", "DEBUG=true" ], binds: instance_of(Array))
    expect_main_container(
      cmd: [ "echo", "test" ],
      output: "\x04test",
      env: [ "NODE_ENV=development", "DEBUG=true" ],
      binds: includes(regexp_matches(/summoncircle_workplace_volume_.*:\/workspace/))
    )
    expect_git_diff_container

    run.execute!

    assert run.completed?
    assert_equal 3, run.steps.count
  end

  test "execute! clones repository on first run with default repo_path" do
    task = tasks(:for_repo_clone)
    run = task.runs.create!(prompt: "test", status: :pending)

    # Mock git container creation and execution
    expect_git_clone_container(
      log_output: "Cloning into '.'...",
      cmd: [ "-c", "git clone 'https://github.com/test/repo.git' '.'" ],
      working_dir: "/workspace",
      binds: instance_of(Array)
    )
    
    # Expect branch detection after clone
    expect_branch_detection_container(
      working_dir: "/workspace",
      branch: "main",
      binds: instance_of(Array)
    )

    expect_main_container(cmd: [ "echo", "STARTING: test" ], output: "\x04test")
    expect_git_diff_container

    run.execute!

    assert run.completed?
    assert_equal 3, run.steps.count
  end

  test "execute! clones repository on first run with custom repo_path" do
    task = tasks(:for_repo_clone_with_path)
    run = task.runs.create!(prompt: "test", status: :pending)

    # Mock git container creation and execution
    expect_git_clone_container(
      log_output: "Cloning into '/workspace/myapp'...",
      cmd: [ "-c", "git clone 'https://github.com/test/repo.git' 'myapp'" ],
      working_dir: "/workspace",
      binds: instance_of(Array)
    )
    
    # Expect branch detection after clone
    expect_branch_detection_container(
      working_dir: "/workspace/myapp",
      branch: "main",
      binds: instance_of(Array)
    )

    expect_main_container(cmd: [ "echo", "STARTING: test" ], output: "\x04test")
    expect_git_diff_container

    run.execute!

    assert run.completed?
    assert_equal 3, run.steps.count
  end

  test "execute! handles git clone failure" do
    task = tasks(:for_repo_clone)
    run = task.runs.create!(prompt: "test", status: :pending)

    # Mock git container creation and execution with failure
    expect_git_clone_container(
      log_output: "fatal: repository not found",
      status_code: 1
    )

    # No chmod container expected since git clone fails

    run.execute!

    assert run.failed?
    assert_equal 1, run.steps.count
    assert_includes run.steps.first.raw_response, "Git operation error"
  end

  test "execute! skips git clone on subsequent runs" do
    task = tasks(:task_with_runs)
    run = task.runs.last
    run.update!(status: :pending, started_at: nil, completed_at: nil)
    run.steps.destroy_all

    # Mock main container
    expect_main_container(cmd: [ "echo hello" ], output: "\x04test")

    # Expect git diff container to be created after run completes
    expect_git_diff_container

    run.execute!

    assert run.completed?
    assert_equal 3, run.steps.count
  end

  test "should_clone_repository? returns false when repository_url is blank" do
    task = tasks(:for_skip_git_clone)
    run = task.runs.create!(prompt: "test")

    assert_not run.send(:should_clone_repository?)
  end

  test "should_clone_repository? returns true when repository_url is present" do
    task = tasks(:for_repo_clone)
    run = task.runs.create!(prompt: "test")

    assert run.send(:should_clone_repository?)
  end

  test "execute! skips git clone when repository_url is blank" do
    task = tasks(:for_skip_git_clone)
    run = task.runs.create!(prompt: "test", status: :pending)

    # Ensure Docker::Container.create is only called once (for main container, not git)
    expect_main_container(cmd: [ "echo", "STARTING: test" ], output: "\x04test")

    run.execute!

    assert run.completed?
    assert_equal 2, run.steps.count # No repo state step since no repository_url
  end

  test "execute! runs setup script on first run when present" do
    task = tasks(:for_repo_clone)
    project = task.project
    project.update!(setup_script: "npm install && npm run build")
    run = task.runs.create!(prompt: "test", status: :pending)

    expect_clone_and_branch_detection(binds: instance_of(Array))
    expect_setup_script_container(
      cmd: [ "-c", "npm install && npm run build" ],
      output: "\x00Setup complete!"
    )
    expect_main_container(cmd: [ "echo", "STARTING: test" ], output: "\x04test")
    expect_git_diff_container

    run.execute!

    assert run.completed?
    assert_equal 4, run.steps.count
    setup_step = run.steps.find { |s| s.content&.start_with?("Setup script executed") }
    assert_not_nil setup_step
    assert_includes setup_step.content, "Setup complete!"
  end

  test "execute! skips setup script on subsequent runs" do
    task = tasks(:task_with_runs)
    project = task.project
    project.update!(setup_script: "npm install")
    run = task.runs.last
    run.update!(status: :pending, started_at: nil, completed_at: nil)
    run.steps.destroy_all

    expect_main_container(cmd: [ "echo hello" ], output: "\x04test")
    expect_git_diff_container

    run.execute!

    assert run.completed?
    assert_equal 3, run.steps.count
    assert_nil run.steps.find { |s| s.content&.start_with?("Setup script executed") }
  end

  test "execute! handles setup script failure" do
    task = tasks(:for_repo_clone)
    project = task.project
    project.update!(setup_script: "exit 1")
    run = task.runs.create!(prompt: "test", status: :pending)

    expect_clone_and_branch_detection(binds: instance_of(Array))
    expect_setup_script_container(
      cmd: [ "-c", "exit 1" ],
      output: "Setup failed!",
      status_code: 1
    )

    run.execute!

    assert run.failed?
    assert_equal 1, run.steps.count
    assert_includes run.steps.first.raw_response, "Setup script failed"
  end

  test "execute! runs setup script with project environment variables" do
    task = tasks(:for_repo_clone)
    project = task.project
    project.update!(setup_script: "echo $API_KEY")
    project.secrets.create!(key: "API_KEY", value: "secret_123")
    run = task.runs.create!(prompt: "test", status: :pending)

    expect_clone_and_branch_detection(env: [ "API_KEY=secret_123" ], binds: instance_of(Array))
    expect_setup_script_container(
      cmd: [ "-c", "echo $API_KEY" ],
      output: "secret_123",
      env: [ "API_KEY=secret_123" ]
    )
    expect_main_container(cmd: [ "echo", "STARTING: test" ], output: "\x04test", env: [ "API_KEY=secret_123" ])
    expect_git_diff_container

    run.execute!

    assert run.completed?
    assert_equal 4, run.steps.count
  end

  test "execute! clones SSH repository with SSH key on first run" do
    task = tasks(:for_repo_clone)
    agent = task.agent
    agent.update!(ssh_mount_path: "/home/user/.ssh/id_rsa")

    user = task.user
    user.update!(ssh_key: "-----BEGIN OPENSSH PRIVATE KEY-----\ntest_ssh_key\n-----END OPENSSH PRIVATE KEY-----")

    project = task.project
    project.update!(repository_url: "git@github.com:test/repo.git")

    run = task.runs.create!(prompt: "test", status: :pending)

    # Mock git container creation for SSH clone with wrapper script
    git_container = mock("git_container")
    git_container.expects(:start)
    git_container.expects(:exec).with([ "mkdir", "-p", "/home/user/.ssh" ])
    git_container.expects(:exec).with([ "sh", "-c", "echo 'LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0KdGVzdF9zc2hfa2V5Ci0tLS0tRU5EIE9QRU5TU0ggUFJJVkFURSBLRVktLS0tLQ==' | base64 -d > /home/user/.ssh/id_rsa" ])
    git_container.expects(:exec).with([ "chmod", "600", "/home/user/.ssh/id_rsa" ])
    git_container.expects(:exec).with([ "chmod", "700", "/home/user/.ssh" ])
    git_container.expects(:wait).with(300).returns({ "StatusCode" => 0 })
    git_container.expects(:logs).with(stdout: true, stderr: true).returns(DOCKER_LOG_HEADER + "Cloning into '.'...")
    git_container.expects(:delete).with(force: true)

    Docker::Container.expects(:create).with(
      has_entries(
        "Image" => "example/image:latest",
        "Entrypoint" => [ "sh" ],
        "Cmd" => [ "-c", "git clone 'git@github.com:test/repo.git' '.'" ],
        "WorkingDir" => "/workspace",
        "User" => "1000",
        "Env" => [],
        "HostConfig" => has_entries("Binds" => instance_of(Array))
      )
    ).returns(git_container)
    
    # Mock branch detection container (also gets SSH setup)
    branch_container = mock("branch_container")
    branch_container.expects(:start)
    branch_container.expects(:exec).with([ "mkdir", "-p", "/home/user/.ssh" ])
    branch_container.expects(:exec).with([ "sh", "-c", "echo 'LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0KdGVzdF9zc2hfa2V5Ci0tLS0tRU5EIE9QRU5TU0ggUFJJVkFURSBLRVktLS0tLQ==' | base64 -d > /home/user/.ssh/id_rsa" ])
    branch_container.expects(:exec).with([ "chmod", "600", "/home/user/.ssh/id_rsa" ])
    branch_container.expects(:exec).with([ "chmod", "700", "/home/user/.ssh" ])
    branch_container.expects(:wait).returns({ "StatusCode" => 0 })
    branch_container.expects(:logs).returns(DOCKER_LOG_HEADER + "main")
    branch_container.expects(:delete).with(force: true)
    
    Docker::Container.expects(:create).with(
      has_entries(
        "Image" => "example/image:latest",
        "Entrypoint" => [ "sh" ],
        "Cmd" => [ "-c", "git branch --show-current" ],
        "WorkingDir" => "/workspace",
        "User" => "1000"
      )
    ).returns(branch_container)

    # Mock main container with SSH key mount verification
    main_container = mock("main_container")
    main_container.expects(:start)
    main_container.expects(:wait).returns({ "StatusCode" => 0 })
    main_container.expects(:logs).with(stdout: true, stderr: true).returns(DOCKER_LOG_HEADER + "test")
    main_container.expects(:delete).with(force: true)

    # Expect SSH key to be copied to container
    run.expects(:archive_file_to_container).with do |container, content, path, mode|
      if path&.include?("/.ssh/")
        assert_equal user.ssh_key, content
        assert_equal 0o600, mode
      end
      true
    end.at_least_once

    Docker::Container.expects(:create).with(
      has_entries(
        "Image" => "example/image:latest",
        "Cmd" => [ "echo", "STARTING: test" ],
        "WorkingDir" => "/workspace"
      )
    ).returns(main_container)

    # Mock git diff container with SSH support
    git_diff_container = mock("git_diff_container")
    git_diff_container.expects(:start)
    git_diff_container.expects(:exec).with([ "mkdir", "-p", "/home/user/.ssh" ])
    git_diff_container.expects(:exec).with([ "sh", "-c", "echo 'LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0KdGVzdF9zc2hfa2V5Ci0tLS0tRU5EIE9QRU5TU0ggUFJJVkFURSBLRVktLS0tLQ==' | base64 -d > /home/user/.ssh/id_rsa" ])
    git_diff_container.expects(:exec).with([ "chmod", "600", "/home/user/.ssh/id_rsa" ])
    git_diff_container.expects(:exec).with([ "chmod", "700", "/home/user/.ssh" ])
    git_diff_container.expects(:wait).with(300).returns({ "StatusCode" => 0 })
    git_diff_container.expects(:logs).with(stdout: true, stderr: true).returns(DOCKER_LOG_HEADER + "diff --git...")
    git_diff_container.expects(:delete).with(force: true)

    Docker::Container.expects(:create).with(
      has_entries(
        "Image" => "example/image:latest",
        "Entrypoint" => [ "sh" ],
        "Cmd" => [ "-c", "git add -N . && git diff HEAD --unified=10" ],
        "WorkingDir" => "/workspace",
        "User" => "1000",
        "Env" => [],
        "HostConfig" => has_entries("Binds" => instance_of(Array))
      )
    ).returns(git_diff_container)
    
    # Mock target branch diff container with SSH support
    target_diff_container = mock("target_diff_container")
    target_diff_container.expects(:start)
    target_diff_container.expects(:exec).with([ "mkdir", "-p", "/home/user/.ssh" ])
    target_diff_container.expects(:exec).with([ "sh", "-c", "echo 'LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0KdGVzdF9zc2hfa2V5Ci0tLS0tRU5EIE9QRU5TU0ggUFJJVkFURSBLRVktLS0tLQ==' | base64 -d > /home/user/.ssh/id_rsa" ])
    target_diff_container.expects(:exec).with([ "chmod", "600", "/home/user/.ssh/id_rsa" ])
    target_diff_container.expects(:exec).with([ "chmod", "700", "/home/user/.ssh" ])
    target_diff_container.expects(:wait).returns({ "StatusCode" => 0 })
    target_diff_container.expects(:logs).returns(DOCKER_LOG_HEADER + "")
    target_diff_container.expects(:delete).with(force: true)

    Docker::Container.expects(:create).with(
      has_entries(
        "Image" => "example/image:latest",
        "Entrypoint" => [ "sh" ],
        "Cmd" => [ "-c", anything ], # git fetch and diff command
        "WorkingDir" => "/workspace",
        "User" => "1000"
      )
    ).returns(target_diff_container)

    run.execute!

    assert run.completed?
    assert_equal 3, run.steps.count
  end

  test "execute! configures MCP on first run when endpoint present" do
    task = tasks(:with_mcp_endpoint)
    run = task.runs.create!(prompt: "test", status: :pending)

    expect_clone_and_branch_detection(binds: instance_of(Array))
    expect_mcp_container(
      cmd: [ "mcp", "add", "summoncircle", "http://localhost:3000/mcp/sse", "-s", "user", "-t", "sse" ],
      output: "MCP configured"
    )
    expect_main_container(cmd: [ "echo", "test" ], output: "\x04test")
    expect_git_diff_container

    run.execute!

    assert run.completed?
    assert_equal 3, run.steps.count
  end

  test "execute! appends /mcp/sse to endpoint URL if not present" do
    task = tasks(:with_mcp_endpoint)
    run = task.runs.create!(prompt: "test", status: :pending)

    expect_clone_and_branch_detection(binds: instance_of(Array))
    expect_mcp_container(
      cmd: [ "mcp", "add", "summoncircle", "http://localhost:3000/mcp/sse", "-s", "user", "-t", "sse" ],
      output: "MCP configured"
    )
    expect_main_container(cmd: [ "echo", "test" ], output: "\x04test")
    expect_git_diff_container

    run.execute!

    assert run.completed?
  end

  test "execute! does not duplicate /mcp/sse if already present in endpoint" do
    task = tasks(:with_mcp_endpoint_full_url)
    run = task.runs.create!(prompt: "test", status: :pending)

    expect_clone_and_branch_detection(binds: instance_of(Array))
    expect_mcp_container(
      cmd: [ "mcp", "add", "summoncircle", "http://localhost:3000/mcp/sse", "-s", "user", "-t", "sse" ],
      output: "MCP configured"
    )
    expect_main_container(cmd: [ "echo", "test" ], output: "\x04test")
    expect_git_diff_container

    run.execute!

    assert run.completed?
  end

  test "execute! skips MCP configuration on subsequent runs" do
    task = tasks(:with_mcp_endpoint_has_runs)
    run = task.runs.create!(prompt: "test", status: :pending)

    expect_main_container(cmd: [ "echo hello" ], output: "\x04test")
    expect_git_diff_container

    run.execute!

    assert run.completed?
    assert_equal 3, run.steps.count
  end

  test "execute! skips MCP configuration when endpoint is blank" do
    task = tasks(:without_runs)
    run = task.runs.create!(prompt: "test", status: :pending)

    expect_clone_and_branch_detection(binds: instance_of(Array))
    expect_main_container(cmd: [ "echo", "STARTING: test" ], output: "\x04test")
    expect_git_diff_container

    run.execute!

    assert run.completed?
    assert_equal 3, run.steps.count
  end

  test "execute! handles MCP configuration failure" do
    task = tasks(:with_mcp_endpoint)
    run = task.runs.create!(prompt: "test", status: :pending)

    expect_clone_and_branch_detection(binds: instance_of(Array))
    expect_mcp_container(
      cmd: [ "mcp", "add", "summoncircle", "http://localhost:3000/mcp/sse", "-s", "user", "-t", "sse" ],
      output: "MCP error: connection refused",
      status_code: 1
    )

    run.execute!

    assert run.failed?
    assert_equal 1, run.steps.count
    assert_includes run.steps.first.raw_response, "Failed to configure MCP"
    assert_includes run.steps.first.raw_response, "connection refused"
  end

  test "execute! cleans up MCP container even on failure" do
    task = tasks(:with_mcp_endpoint)
    run = task.runs.create!(prompt: "test", status: :pending)

    mcp_container = mock("mcp_container")
    mcp_container.expects(:start)
    mcp_container.expects(:wait).returns({ "StatusCode" => 1 })
    mcp_container.expects(:logs).with(stdout: true, stderr: true).returns(DOCKER_LOG_HEADER + "MCP error")
    mcp_container.expects(:delete).with(force: true)

    expect_clone_and_branch_detection(binds: instance_of(Array))
    Docker::Container.expects(:create).with(
      has_entries(
        "Image" => "example/image:latest",
        "Cmd" => [ "mcp", "add", "summoncircle", "http://localhost:3000/mcp/sse", "-s", "user", "-t", "sse" ]
      )
    ).returns(mcp_container)

    run.execute!

    assert run.failed?
  end

  test "execute! fails with helpful error when SSH repository but no SSH key configured" do
    task = tasks(:for_repo_clone)
    task.user.update!(ssh_key: nil)
    task.project.update!(repository_url: "git@github.com:test/repo.git")
    run = task.runs.create!(prompt: "test", status: :pending)

    run.execute!

    assert run.failed?
    assert_equal 1, run.steps.count
    assert_includes run.steps.first.raw_response, "SSH authentication required"
    assert_includes run.steps.first.raw_response, "no SSH key is configured"
    assert_includes run.steps.first.raw_response, "Please add an SSH key in your user settings"
  end

  test "execute! fails with helpful error when SSH repository but agent lacks SSH mount path" do
    task = tasks(:for_repo_clone)
    task.user.update!(ssh_key: "test_key")
    task.agent.update!(ssh_mount_path: nil)
    task.project.update!(repository_url: "git@github.com:test/repo.git")
    run = task.runs.create!(prompt: "test", status: :pending)

    run.execute!

    assert run.failed?
    assert_equal 1, run.steps.count
    assert_includes run.steps.first.raw_response, "SSH configuration incomplete"
    assert_includes run.steps.first.raw_response, "Please configure the agent's SSH mount path"
  end

  test "execute! provides helpful SSH authentication error when git clone fails with permission denied" do
    task = tasks(:for_repo_clone)
    task.user.update!(ssh_key: "test_key")
    task.agent.update!(ssh_mount_path: "/home/user/.ssh/id_rsa")
    task.project.update!(repository_url: "git@github.com:test/repo.git")
    run = task.runs.create!(prompt: "test", status: :pending)

    # Mock git container creation and execution with SSH failure
    git_container = mock("git_container")
    git_container.expects(:start)
    git_container.expects(:exec).with([ "mkdir", "-p", "/home/user/.ssh" ])
    git_container.expects(:exec).with([ "sh", "-c", "echo 'dGVzdF9rZXk=' | base64 -d > /home/user/.ssh/id_rsa" ])
    git_container.expects(:exec).with([ "chmod", "600", "/home/user/.ssh/id_rsa" ])
    git_container.expects(:exec).with([ "chmod", "700", "/home/user/.ssh" ])
    git_container.expects(:wait).with(300).returns({ "StatusCode" => 128 })
    git_container.expects(:logs).with(stdout: true, stderr: true).returns(
      DOCKER_LOG_HEADER + "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository."
    )
    git_container.expects(:delete).with(force: true)

    Docker::Container.expects(:create).with(
      has_entries(
        "Image" => "example/image:latest",
        "Entrypoint" => [ "sh" ],
        "Cmd" => [ "-c", "git clone 'git@github.com:test/repo.git' '.'" ]
      )
    ).returns(git_container)

    run.execute!

    assert run.failed?
    assert_equal 1, run.steps.count
    assert_includes run.steps.first.raw_response, "SSH authentication failed"
    assert_includes run.steps.first.raw_response, "SSH key may not have access to this repository"
    assert_includes run.steps.first.raw_response, "deploy keys"
  end

  private

  def expect_broadcast_refresh
    Run.any_instance.expects(:broadcast_refresh_auto_push_form).once
  end

  def mock_container_with_output(output)
    mock_container = mock("container")
    mock_container.expects(:start)
    mock_container.expects(:wait).returns({ "StatusCode" => 0 })
    mock_container.expects(:logs).with(stdout: true, stderr: true).returns(DOCKER_LOG_HEADER + output)
    mock_container.expects(:delete).with(force: true)
    mock_container
  end

  def mock_git_container(log_output: "Cloning...", status_code: 0)
    git_container = mock("git_container")
    git_container.expects(:start)
    git_container.expects(:wait).returns({ "StatusCode" => status_code })
    git_container.expects(:logs).with(stdout: true, stderr: true).returns(DOCKER_LOG_HEADER + log_output)
    git_container.expects(:delete).with(force: true)
    git_container
  end
  
  def expect_clone_and_branch_detection(clone_cmd: nil, working_dir: "/workspace", env: [], binds: nil, project: nil)
    # If clone_cmd is not provided, generate it based on project
    if clone_cmd.nil? && project
      clone_cmd = "git clone '#{project.repository_url}' '.'"
    end
    clone_cmd ||= "git clone 'https://github.com/test/repo.git' '.'"
    
    # Expect clone
    git_container = mock_git_container(log_output: "Cloning into '.'...")
    expectations = {
      "Image" => "example/image:latest",
      "Entrypoint" => [ "sh" ],
      "Cmd" => [ "-c", clone_cmd ],
      "WorkingDir" => working_dir,
      "User" => "1000",
      "Env" => env
    }
    expectations["HostConfig"] = has_entries("Binds" => binds) if binds
    
    Docker::Container.expects(:create).with(has_entries(expectations)).returns(git_container)
    
    # Expect branch detection
    branch_container = mock_git_container(log_output: "main", status_code: 0)
    branch_expectations = {
      "Image" => "example/image:latest",
      "Entrypoint" => [ "sh" ],
      "Cmd" => [ "-c", "git branch --show-current" ],
      "WorkingDir" => working_dir,
      "User" => "1000",
      "Env" => env
    }
    branch_expectations["HostConfig"] = has_entries("Binds" => binds) if binds
    
    Docker::Container.expects(:create).with(has_entries(branch_expectations)).returns(branch_container)
  end

  def expect_git_clone_container(image: "example/image:latest", user: "1000", log_output: "Cloning...", status_code: 0, cmd: nil, working_dir: nil, binds: nil)
    git_container = mock_git_container(log_output: log_output, status_code: status_code)

    expectations = {
      "Image" => image,
      "Entrypoint" => [ "sh" ],
      "User" => user
    }

    expectations["Cmd"] = cmd if cmd
    expectations["WorkingDir"] = working_dir if working_dir
    expectations["HostConfig"] = has_entries("Binds" => binds) if binds

    Docker::Container.expects(:create).with(
      has_entries(expectations)
    ).returns(git_container)
  end

  def expect_branch_detection_container(working_dir: "/workspace/myapp", branch: "main", image: "example/image:latest", user: "1000", binds: nil)
    branch_container = mock_git_container(log_output: branch, status_code: 0)
    
    expectations = {
      "Image" => image,
      "Entrypoint" => [ "sh" ],
      "Cmd" => [ "-c", "git branch --show-current" ],
      "WorkingDir" => working_dir,
      "User" => user
    }
    
    expectations["HostConfig"] = has_entries("Binds" => binds) if binds

    Docker::Container.expects(:create).with(
      has_entries(expectations)
    ).returns(branch_container)
  end

  def expect_main_container(cmd:, output:, image: "example/image:latest", env: [], working_dir: "/workspace", binds: nil)
    expectations = {
      "Image" => image,
      "Cmd" => cmd,
      "WorkingDir" => working_dir
    }

    expectations["Env"] = env unless env.nil?

    if binds
      expectations["HostConfig"] = has_entries("Binds" => binds)
    end

    Docker::Container.expects(:create).with(
      has_entries(expectations)
    ).returns(mock_container_with_output(output))
  end

  def expect_git_diff_container(expect_target_branch_diff: true)
    git_diff_container = mock("git_diff_container")
    git_diff_container.expects(:start)
    git_diff_container.expects(:wait).returns({ "StatusCode" => 0 })
    git_diff_container.expects(:logs).with(stdout: true, stderr: true).returns(DOCKER_LOG_HEADER + "")
    git_diff_container.expects(:delete).with(force: true)

    Docker::Container.expects(:create).with(
      has_entries(
        "Entrypoint" => [ "sh" ],
        "Cmd" => [ "-c", "git add -N . && git diff HEAD --unified=10" ],
        "User" => "1000"
      )
    ).returns(git_diff_container)
    
    # Expect target branch diff if task has target_branch set
    if expect_target_branch_diff
      target_diff_container = mock("target_diff_container")
      target_diff_container.expects(:start)
      target_diff_container.expects(:wait).returns({ "StatusCode" => 0 })
      target_diff_container.expects(:logs).with(stdout: true, stderr: true).returns(DOCKER_LOG_HEADER + "")
      target_diff_container.expects(:delete).with(force: true)

      Docker::Container.expects(:create).with(
        has_entries(
          "Entrypoint" => [ "sh" ],
          "Cmd" => [ "-c", anything ],
          "User" => "1000"
        )
      ).returns(target_diff_container)
    end
  end

  def expect_setup_script_container(cmd:, output:, status_code: 0, env: nil)
    setup_container = mock("setup_container")
    setup_container.expects(:start)
    setup_container.expects(:wait).returns({ "StatusCode" => status_code })
    setup_container.expects(:logs).with(stdout: true, stderr: true).returns(DOCKER_LOG_HEADER + output)
    setup_container.expects(:delete).with(force: true)

    expectations = {
      "Image" => "example/image:latest",
      "Entrypoint" => [ "sh" ],
      "Cmd" => cmd,
      "WorkingDir" => "/workspace",
      "User" => "1000"
    }

    expectations["Env"] = env if env
    expectations["HostConfig"] = has_entries("Binds" => instance_of(Array))

    Docker::Container.expects(:create).with(
      has_entries(expectations)
    ).returns(setup_container)
  end

  def expect_mcp_container(cmd:, output:, status_code: 0, env: nil)
    mcp_container = mock("mcp_container")
    mcp_container.expects(:start)
    mcp_container.expects(:wait).returns({ "StatusCode" => status_code })
    if status_code != 0
      mcp_container.expects(:logs).with(stdout: true, stderr: true).returns(DOCKER_LOG_HEADER + output)
    end
    mcp_container.expects(:delete).with(force: true)

    expectations = {
      "Image" => "example/image:latest",
      "Cmd" => cmd,
      "WorkingDir" => "/workspace",
      "User" => "1000"
    }

    expectations["Env"] = env if env
    expectations["HostConfig"] = has_entries("Binds" => instance_of(Array))

    Docker::Container.expects(:create).with(
      has_entries(expectations)
    ).returns(mcp_container)
  end
end
