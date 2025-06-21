module GitOperations
  extend ActiveSupport::Concern

  def clone_repository(task = nil)
    task ||= self.is_a?(Task) ? self : self.task
    project = task.project
    repo_path = project.repo_path.presence || ""
    clone_target = repo_path.presence&.sub(/^\//, "") || "."
    repository_url = project.repository_url

    Rails.logger.info "Clone repository - URL: #{repository_url.inspect}, Branch: #{task.target_branch.inspect}"
    validate_ssh_setup!(task, repository_url)

    if task.target_branch.present?
      command = "git clone -b '#{task.target_branch}' '#{repository_url}' '#{clone_target}'"
    else
      # Clone without specifying branch, then detect and save the default branch
      command = "git clone '#{repository_url}' '#{clone_target}'"
    end

    Rails.logger.info "Clone command: #{command}"

    run_git_command(
      task: task,
      command: command,
      working_dir: task.workplace_mount.container_path,
      error_message: "Failed to clone repository",
      skip_repo_path: true  # Clone operates from workspace root
    )

    # If target_branch was nil, detect and save the default branch
    if task.target_branch.blank?
      detect_and_save_default_branch(task)
    end
  end

  def detect_and_save_default_branch(task)
    begin
      # Get the current branch name (which will be the default after clone)
      logs = run_git_command(
        task: task,
        command: "git branch --show-current",
        error_message: "Failed to detect current branch",
        return_logs: true
      )

      default_branch = logs.strip
      if default_branch.present?
        task.update_column(:target_branch, default_branch)
        Rails.logger.info "Set target_branch to detected default: #{default_branch}"
      end
    rescue => e
      Rails.logger.error "Failed to detect default branch: #{e.message}"
    end
  end

  def push_changes_to_branch(commit_message = nil)
    task = self.is_a?(Task) ? self : self.task
    return unless task.auto_push_enabled? && task.auto_push_branch.present?
    return unless task.project.repository_url.present?

    repository_url = task.project.repository_url
    commit_message ||= "Manual push from SummonCircle"

    validate_ssh_setup!(task, repository_url)

    push_commands = [
      "git remote set-url origin '#{repository_url}'",
      "git add -A",
      "git diff --cached --quiet || git commit -m '#{commit_message}'",
      "git push origin HEAD:#{task.auto_push_branch}"
    ].join(" && ")

    run_git_command(
      task: task,
      command: push_commands,
      error_message: "Failed to push changes"
    )
  end



  def fetch_branches(task = nil)
    task ||= self.is_a?(Task) ? self : self.task
    return [] unless task.project.repository_url.present?

    begin
      logs = run_git_command(
        task: task,
        command: "git branch",
        error_message: "Failed to fetch branches",
        return_logs: true
      )

      branches = logs.lines.map do |line|
        # Remove the * for current branch and any whitespace
        line.strip.sub(/^\*\s*/, "")
      end.reject(&:blank?)

      branches.presence || []
    rescue => e
      Rails.logger.error "Failed to fetch branches: #{e.message}"
      []
    end
  end

  def capture_repository_state(run = nil)
    run ||= self if self.is_a?(Run)
    task = run.task
    project = task.project
    return nil unless project.repository_url.present?

    begin
      command = "git add -N . && git diff HEAD --unified=10"

      diff_output = run_git_command(
        task: task,
        command: command,
        error_message: "Failed to capture git diff",
        return_logs: true
      )

      target_branch_diff = nil
      if task.target_branch.present?
        begin
          target_command = "git fetch origin #{task.target_branch} && git diff origin/#{task.target_branch}...HEAD --unified=10"
          target_branch_diff = run_git_command(
            task: task,
            command: target_command,
            error_message: "Failed to capture target branch diff",
            return_logs: true
          )
        rescue => e
          Rails.logger.error "Failed to capture target branch diff: #{e.message}"
        end
      end

      # Return early only if both diffs are empty
      return nil if diff_output.blank? && target_branch_diff.blank?

      repo_path = project.repo_path.presence || ""
      working_dir = task.workplace_mount.container_path
      git_working_dir = File.join([ working_dir, repo_path.presence&.sub(/^\//, "") ].compact)

      repo_state_step = run.steps.create!(
        raw_response: "Repository state captured",
        type: "Step::System",
        content: "Repository state captured"
      )

      repo_state_step.repo_states.create!(
        uncommitted_diff: diff_output,
        target_branch_diff: target_branch_diff,
        repository_path: git_working_dir
      )
    rescue => e
      Rails.logger.error "Failed to capture repository state: #{e.message}"
      nil
    end
  end

  private

  def run_git_command(task:, command:, error_message:, return_logs: false, working_dir: nil, skip_repo_path: false)
    repo_path = task.project.repo_path.presence || ""
    working_dir ||= task.workplace_mount.container_path
    git_working_dir = if skip_repo_path
      working_dir
    else
      File.join([ working_dir, repo_path.presence&.sub(/^\//, "") ].compact)
    end

    container_config = {
      "Image" => task.agent.docker_image,
      "Entrypoint" => [ "sh" ],
      "Cmd" => [ "-c", command ],
      "WorkingDir" => git_working_dir,
      "User" => task.agent.user_id.to_s,
      "Env" => task.agent.env_strings + task.project.secrets.map { |s| "#{s.key}=#{s.value}" },
      "HostConfig" => {
        "Binds" => task.volume_mounts.includes(:volume).map(&:bind_string)
      }
    }

    container_config = setup_git_credentials(container_config, task.user, task.project.repository_url)

    git_container = Docker::Container.create(container_config)
    git_container.start

    # Setup SSH key if needed for SSH URLs
    if task.project.repository_url&.match?(/\Agit@|ssh:\/\//)
      setup_ssh_key_in_container(git_container, task)
    end

    wait_result = git_container.wait(300)
    logs = git_container.logs(stdout: true, stderr: true)
    clean_logs = logs.gsub(/^.{8}/m, "").force_encoding("UTF-8").scrub.strip
    exit_code = wait_result["StatusCode"] if wait_result.is_a?(Hash)

    if exit_code && exit_code != 0
      enhanced_error = enhance_git_error_message(clean_logs, task, command)
      raise enhanced_error
    end

    return_logs ? clean_logs : nil
  rescue => e
    raise "Git operation error: #{e.message} (#{e.class})"
  ensure
    git_container&.delete(force: true) if defined?(git_container)
  end

  def setup_git_credentials(container_config, user, repository_url)
    platform = git_platform_from_url(repository_url)
    return container_config unless platform

    platform_config = credentials_for(user, platform)
    return container_config unless platform_config

    container_config["Env"] ||= []
    container_config["Env"] << "#{platform_config[:env_var]}=#{platform_config[:token]}"
    container_config["Env"] << "GIT_ASKPASS=/tmp/git-askpass.sh"

    container_config["Cmd"] = wrap_with_credential_setup(container_config["Cmd"], platform_config)
    container_config
  end

  private

  def git_platform_from_url(url)
    return nil unless url.present?

    case url
    when /github\.com/
      :github
    else
      nil
    end
  end

  def credentials_for(user, platform)
    case platform
    when :github
      return nil unless user&.github_token.present?
      {
        username: "x-access-token",
        env_var: "GITHUB_TOKEN",
        token: user.github_token
      }
    else
      nil
    end
  end

  def wrap_with_credential_setup(original_cmd, platform_config)
    askpass_script = generate_askpass_script(platform_config)

    setup_script = <<~BASH.strip
      echo '#{askpass_script}' > /tmp/git-askpass.sh && \
      chmod +x /tmp/git-askpass.sh
    BASH

    if original_cmd.is_a?(Array) && original_cmd[0] == "-c"
      [ "-c", "#{setup_script} && #{original_cmd[1]}" ]
    else
      [ "-c", "#{setup_script} && #{Array(original_cmd).join(' ')}" ]
    end
  end

  def generate_askpass_script(platform_config)
    <<~BASH
      #!/bin/sh
      case "$1" in
        Username*) echo "#{platform_config[:username]}" ;;
        Password*) echo "$#{platform_config[:env_var]}" ;;
      esac
    BASH
  end

  def setup_ssh_key_in_container(container, task)
    agent = task.agent
    user = task.user

    return unless user.ssh_key.present? && agent.ssh_mount_path.present?

    encoded_content = Base64.strict_encode64(user.ssh_key)
    target_dir = File.dirname(agent.ssh_mount_path)

    # Create .ssh directory
    container.exec([ "mkdir", "-p", target_dir ])

    # Write SSH key
    container.exec([ "sh", "-c", "echo '#{encoded_content}' | base64 -d > #{agent.ssh_mount_path}" ])

    # Set permissions
    container.exec([ "chmod", "600", agent.ssh_mount_path ])
    container.exec([ "chmod", "700", target_dir ])
  rescue => e
    Rails.logger.error "Failed to setup SSH key in container: #{e.message}"
  end

  def validate_ssh_setup!(task, repository_url)
    return unless repository_url&.match?(/\Agit@|ssh:\/\//)

    user = task.user
    agent = task.agent

    if user.ssh_key.blank?
      raise "SSH authentication required: The repository uses SSH authentication but no SSH key is configured. Please add an SSH key in your user settings."
    end

    if agent.ssh_mount_path.blank?
      raise "SSH configuration incomplete: The agent does not have an SSH mount path configured. Please configure the agent's SSH mount path."
    end
  end

  def enhance_git_error_message(original_error, task, command)
    if original_error.include?("Permission denied (publickey)") || original_error.include?("Could not read from remote repository")
      user = task.user
      agent = task.agent

      if task.project.repository_url&.match?(/\Agit@|ssh:\/\//)
        if user.ssh_key.blank?
          return "SSH authentication failed: No SSH key configured for your user account. Please add an SSH key in your user settings to access this repository."
        elsif agent.ssh_mount_path.blank?
          return "SSH authentication failed: Agent is missing SSH mount path configuration. Please configure the agent's SSH mount path."
        else
          return "SSH authentication failed: The SSH key may not have access to this repository. Please ensure your SSH key is added to the repository's deploy keys or your GitHub/GitLab account."
        end
      end
    end

    "#{original_error}"
  end
end
