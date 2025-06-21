class ProjectBranchesController < ApplicationController
  require "open3"

  before_action :set_project

  def index
    @branches = []
    @default_branch = nil

    if @project.repository_url.present?
      # Use git command directly to fetch branches without creating a task
      @branches = fetch_remote_branches(@project.repository_url)
      @default_branch = fetch_default_branch(@project.repository_url)
    end

    render json: {
      branches: @branches,
      default_branch: @default_branch
    }
  rescue => e
    Rails.logger.error "Failed to fetch branches: #{e.message}"
    render json: { branches: [], default_branch: "main", error: e.message }, status: :unprocessable_entity
  end

  private

  def fetch_remote_branches(repository_url)
    output, status = execute_git_command([ "git", "ls-remote", "--heads", repository_url ], repository_url)
    return [] unless status.success?

    output.lines.map do |line|
      line.split("\t").last.sub("refs/heads/", "").strip if line.include?("refs/heads/")
    end.compact
  end

  def fetch_default_branch(repository_url)
    output, status = execute_git_command([ "git", "ls-remote", "--symref", repository_url, "HEAD" ], repository_url)
    return "main" unless status.success?

    if output.include?("refs/heads/")
      output.lines.first.split("\t").first.sub("ref: refs/heads/", "").strip
    else
      "main"
    end
  end

  def execute_git_command(command_array, repository_url)
    env = {}
    askpass_script = nil

    # Check if it's a GitHub HTTPS URL and we have a token
    if repository_url.include?("github.com") && repository_url.start_with?("https://") && Current.user&.github_token.present?
      # Create a temporary askpass script
      askpass_script = Tempfile.new([ "git-askpass", ".sh" ])
      askpass_script.write(<<~BASH)
        #!/bin/sh
        case "$1" in
          Username*) echo "x-access-token" ;;
          Password*) echo "#{Current.user.github_token}" ;;
        esac
      BASH
      askpass_script.close
      File.chmod(0700, askpass_script.path)

      env["GIT_ASKPASS"] = askpass_script.path
    end

    # Execute command with Open3 to avoid shell injection
    stdout, stderr, status = Open3.capture3(env, *command_array)
    output = stdout + stderr

    [ output, status ]
  ensure
    # Clean up temp file if created
    askpass_script&.unlink
  end

  def set_project
    @project = Project.find(params[:project_id])
  end
end
