class Run < ApplicationRecord
  include ActionView::RecordIdentifier
  belongs_to :task
  has_many :siblings, through: :task, source: :runs
  has_many :steps, -> { order(:id) }, dependent: :destroy

  enum :status, { pending: 0, running: 1, completed: 2, failed: 3 }, default: :pending

  after_update_commit :broadcast_update
  after_create_commit :broadcast_chat_append
  after_update_commit :broadcast_chat_replace

  def first_run?
    siblings.where.not(id: id).none?
  end

  def repo_states
    RepoState.joins(:step).where(step: steps)
  end

  def execute!
    running!
    update!(started_at: Time.current)

    begin
      set_docker_host(task.agent.docker_host)
      clone_repository if first_run? && should_clone_repository?
      run_setup_script

      if task.agent.mcp_sse_endpoint.present? && first_run?
        configure_mcp
      end

      container = create_container
      container.start
      setup_container_files(container)

      processor = task.agent.log_processor_class.new
      processor.process_container(container, self)
      capture_repository_state
      push_changes_if_enabled
      completed!
      broadcast_refresh_auto_push_form
    rescue => e
      error_message = "Error: #{e.message}\nBacktrace: #{e.backtrace.first(5).join("\n")}"
      Rails.logger.error "Run execution failed: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")

      # Create an error step with the error message
      steps.create!(raw_response: error_message, type: "Step::Error", content: error_message)
      failed!
    ensure
      restore_docker_config
      update!(completed_at: Time.current)
      save!
      container&.delete(force: true) if defined?(container)
    end
  end

  def broadcast_update
    broadcast_replace_later_to(task, target: self, partial: "tasks/run", locals: { run: self })
  end

  def broadcast_chat_append
    broadcast_append_to(task, target: "chat-messages", partial: "runs/chat_item", locals: { run: self })
  end

  def broadcast_chat_replace
    broadcast_replace_later_to(task, target: dom_id(self, :chat_item), partial: "runs/chat_item", locals: { run: self })
  end

  def broadcast_refresh_auto_push_form
    broadcast_replace_to(task,
      target: "auto_push_form",
      partial: "tasks/auto_push_form",
      locals: { task: task })
  end

  private


  def set_docker_host(docker_host)
    @original_docker_url ||= Docker.url
    @original_docker_options ||= Docker.options

    return unless docker_host.present?

    Docker.url = docker_host
    Docker.options = {
      read_timeout: 600,
      write_timeout: 600,
      connect_timeout: 60
    }
  end

  def restore_docker_config
    Docker.url = @original_docker_url
    Docker.options = @original_docker_options
  end

  def create_container
    agent = task.agent
    command_template = first_run? ? agent.start_arguments : agent.continue_arguments
    command = command_template.map { |arg| arg.gsub("{PROMPT}", prompt) }

    binds = task.volume_mounts.includes(:volume).map(&:bind_string)
    env_vars = agent.env_strings + project_env_strings

    Docker::Container.create(
      "Image" => agent.docker_image,
      "Cmd" => command,
      "Env" => env_vars,
      "User" => agent.user_id.to_s,
      "WorkingDir" => task.agent.workplace_path,
      "HostConfig" => {
        "Binds" => binds
      }
    )
  end


  def clone_repository
    project = task.project
    repo_path = project.repo_path.presence || ""
    working_dir = task.workplace_mount.container_path
    clone_target = repo_path.presence&.sub(/^\//, "") || "."
    repository_url = project.repository_url_with_token(task.user)

    git_container = Docker::Container.create(
      "Image" => task.agent.docker_image,
      "Entrypoint" => [ "sh" ],
      "Cmd" => [ "-c", "git clone #{repository_url} #{clone_target}" ],
      "WorkingDir" => working_dir,
      "User" => task.agent.user_id.to_s,
      "HostConfig" => {
        "Binds" => [ task.workplace_mount.bind_string ]
      }
    )
    git_container.start
    wait_result = git_container.wait(300)
    logs = git_container.logs(stdout: true, stderr: true)
    clean_logs = logs.gsub(/^.{8}/m, "").force_encoding("UTF-8").scrub.strip
    exit_code = wait_result["StatusCode"] if wait_result.is_a?(Hash)

    if exit_code && exit_code != 0
      raise "Failed to clone repository: #{clean_logs}"
    end
  rescue => e
    raise "Git clone error: #{e.message} (#{e.class})"
  ensure
    git_container&.delete(force: true) if defined?(git_container)
  end

  def should_clone_repository?
    task.project.repository_url.present?
  end

  def capture_repository_state
    return unless should_clone_repository?

    project = task.project
    repo_path = project.repo_path.presence || ""
    working_dir = task.workplace_mount.container_path

    git_working_dir = File.join([ working_dir, repo_path.presence&.sub(/^\//, "") ].compact)

    git_container = Docker::Container.create(
      "Image" => task.agent.docker_image,
      "Entrypoint" => [ "sh" ],
      "Cmd" => [ "-c", "git add -N . && git diff HEAD --unified=10" ],
      "WorkingDir" => git_working_dir,
      "User" => task.agent.user_id.to_s,
      "HostConfig" => {
        "Binds" => [ task.workplace_mount.bind_string ]
      }
    )

    git_container.start
    wait_result = git_container.wait(300)
    logs = git_container.logs(stdout: true, stderr: true)
    uncommitted_diff = logs.gsub(/^.{8}/m, "").force_encoding("UTF-8").scrub.strip

    repo_state_step = steps.create!(
      raw_response: "Repository state captured",
      type: "Step::System",
      content: "Repository state captured\n\nUncommitted diff:\n#{uncommitted_diff}"
    )

    if uncommitted_diff.present?
      repo_state_step.repo_states.create!(
        uncommitted_diff: uncommitted_diff,
        repository_path: git_working_dir
      )
    end
  rescue => e
    Rails.logger.error "Failed to capture repository state: #{e.message}"
  ensure
    git_container&.delete(force: true) if defined?(git_container)
  end

  def project_env_strings
    task.project.secrets.map { |secret| "#{secret.key}=#{secret.value}" }
  end

  def setup_container_files(container)
    agent = task.agent
    user = task.user

    if user.git_config.present? && agent.home_path.present?
      archive_file_to_container(container, user.git_config, File.join(agent.home_path, ".gitconfig"))
    end

    if user.instructions.present? && agent.instructions_mount_path.present?
      archive_file_to_container(container, user.instructions, agent.instructions_mount_path)
    end

    if user.ssh_key.present? && agent.ssh_mount_path.present?
      archive_file_to_container(container, user.ssh_key, agent.ssh_mount_path, 0o600)
    end
  end



  def configure_mcp
    agent = task.agent
    full_url = agent.mcp_sse_endpoint.end_with?("/mcp/sse") ? agent.mcp_sse_endpoint : "#{agent.mcp_sse_endpoint.chomp('/')}/mcp/sse"

    mcp_container = Docker::Container.create(
      "Image" => agent.docker_image,
      "Cmd" => [ "mcp", "add", "summoncircle", full_url, "-s", "user", "-t", "sse" ],
      "Env" => agent.env_strings + project_env_strings,
      "User" => agent.user_id.to_s,
      "WorkingDir" => task.agent.workplace_path,
      "HostConfig" => {
        "Binds" => task.volume_mounts.includes(:volume).map(&:bind_string)
      }
    )

    mcp_container.start
    wait_result = mcp_container.wait(30)
    exit_code = wait_result["StatusCode"] if wait_result.is_a?(Hash)

    if exit_code && exit_code != 0
      logs = mcp_container.logs(stdout: true, stderr: true)
      clean_logs = logs.gsub(/^.{8}/m, "").force_encoding("UTF-8").scrub.strip
      raise "Failed to configure MCP: #{clean_logs}"
    end

    Rails.logger.info "MCP configured successfully for summoncircle at #{full_url}"
  rescue => e
    raise "MCP configuration error: #{e.message}"
  ensure
    mcp_container&.delete(force: true) if defined?(mcp_container)
  end

  def archive_file_to_container(container, content, destination_path, permissions = 0o644)
    target_dir = File.dirname(destination_path)

    container.exec([ "mkdir", "-p", target_dir ])

    encoded_content = Base64.strict_encode64(content)
    container.exec([ "sh", "-c", "echo '#{encoded_content}' | base64 -d > #{destination_path}" ])
    container.exec([ "chmod", permissions.to_s(8), destination_path ])
  end

  def run_setup_script
    return unless first_run? && task.project.setup_script.present?

    project = task.project
    repo_path = project.repo_path.presence || ""
    working_dir = task.workplace_mount.container_path
    setup_working_dir = File.join([ working_dir, repo_path.presence&.sub(/^\//, "") ].compact)

    setup_container = Docker::Container.create(
      "Image" => task.agent.docker_image,
      "Entrypoint" => [ "sh" ],
      "Cmd" => [ "-c", project.setup_script ],
      "WorkingDir" => setup_working_dir,
      "User" => task.agent.user_id.to_s,
      "Env" => task.agent.env_strings + project_env_strings,
      "HostConfig" => {
        "Binds" => task.volume_mounts.includes(:volume).map(&:bind_string)
      }
    )

    setup_container.start
    wait_result = setup_container.wait(600)
    logs = setup_container.logs(stdout: true, stderr: true)
    clean_logs = logs.gsub(/^.{8}/m, "").force_encoding("UTF-8").scrub.strip
    exit_code = wait_result["StatusCode"] if wait_result.is_a?(Hash)

    if exit_code && exit_code != 0
      raise "Setup script failed with exit code #{exit_code}: #{clean_logs}"
    end

    steps.create!(
      raw_response: "Setup script executed",
      type: "Step::System",
      content: "Setup script executed successfully\n\nOutput:\n#{clean_logs}"
    )
  rescue => e
    raise "Setup script error: #{e.message}"
  ensure
    setup_container&.delete(force: true) if defined?(setup_container)
  end

  def push_changes_if_enabled
    return unless task.auto_push_enabled? && task.auto_push_branch.present?

    begin
      task.push_changes_to_branch("Auto-push from SummonCircle run #{id}")
      steps.create!(
        raw_response: "Auto-push completed",
        type: "Step::System",
        content: "Successfully pushed changes to branch: #{task.auto_push_branch}"
      )
    rescue => e
      steps.create!(
        raw_response: "Auto-push failed",
        type: "Step::Error",
        content: "Failed to push changes to branch: #{task.auto_push_branch}\n\nError: #{e.message}"
      )
    end
  end
end
