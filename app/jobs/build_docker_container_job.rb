class BuildDockerContainerJob < ApplicationJob
  queue_as :default

  def perform(task)
    return unless task.project.dev_dockerfile.present?

    set_docker_host(task.agent.docker_host)

    dockerfile_content = task.project.dev_dockerfile
    temp_dir = Rails.root.join("tmp", "docker-build-#{task.id}")
    FileUtils.mkdir_p(temp_dir)
    temp_dockerfile = temp_dir.join("Dockerfile")
    File.write(temp_dockerfile, dockerfile_content)

    image_name = "summoncircle/task-#{task.id}-dev"
    container_name = "task-#{task.id}-dev-container"

    tar_stream = create_tar_stream(temp_dir)
    image = Docker::Image.build_from_tar(tar_stream, t: image_name)

    binds = task.volume_mounts.includes(:volume).map(&:bind_string)
    env_vars = []

    if task.project.secrets.any?
      env_vars = task.project.secrets.map { |s| "#{s.key}=#{s.value}" }
    end

    if task.user.github_token.present? && task.user.allow_github_token_access
      env_vars << "GITHUB_TOKEN=#{task.user.github_token}"
    end

    container_port = task.project.dev_container_port || 3000

    container_config = {
      "name" => container_name,
      "Image" => image_name,
      "WorkingDir" => task.agent.workplace_path,
      "Env" => env_vars,
      "ExposedPorts" => {
        "#{container_port}/tcp" => {}
      },
      "HostConfig" => {
        "Binds" => binds,
        "PublishAllPorts" => true
      }
    }

    # Only set User if agent.user_id is greater than 0 (non-root)
    # Some containers like nginx need to start as root
    if task.agent.user_id && task.agent.user_id > 0
      # For dev containers, we'll let them run as root if needed
      # The user can specify USER in their Dockerfile if needed
      Rails.logger.info "Dev container will run with default user from Dockerfile"
    end

    container = Docker::Container.create(container_config)

    container.start
    container_info = container.json

    task.update!(
      container_id: container.id,
      container_name: container_name,
      container_status: container_info["State"]["Status"],
      docker_image_id: image.id
    )

    broadcast_docker_status(task)
  rescue => e
    Rails.logger.error "Failed to build/run container: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise
  ensure
    FileUtils.rm_rf(temp_dir) if temp_dir && Dir.exist?(temp_dir)
    restore_docker_config
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
    Docker.url = @original_docker_url if @original_docker_url
    Docker.options = @original_docker_options if @original_docker_options
  end

  def create_tar_stream(dir)
    tar_stream = StringIO.new
    Gem::Package::TarWriter.new(tar_stream) do |tar|
      Dir[File.join(dir, "**", "*")].each do |file|
        next if File.directory?(file)

        relative_path = Pathname.new(file).relative_path_from(dir).to_s
        tar.add_file(relative_path, 0644) do |tf|
          tf.write(File.read(file))
        end
      end
    end
    tar_stream.rewind
    tar_stream
  end


  def broadcast_docker_status(task)
    Turbo::StreamsChannel.broadcast_replace_to(
      task,
      target: "docker_controls",
      partial: "tasks/docker_controls",
      locals: { task: task }
    )
  end
end
