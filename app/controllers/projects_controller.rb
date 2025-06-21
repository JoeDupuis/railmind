class ProjectsController < ApplicationController
  def index
    @projects = Project.kept
  end

  def show
    @project = Project.find(params[:id])
  end

  def edit
    @project = Project.find(params[:id])
  end

  def update
    @project = Project.find(params[:id])
    if @project.update(project_params)
      update_project_secrets if params[:project][:secrets].present?
      redirect_to @project, notice: "Project was successfully updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @project = Project.find(params[:id])
    @project.discard
    redirect_to projects_url, notice: "Project was successfully archived."
  end

  def new
    @project = Project.new
  end

  def create
    @project = Project.new(project_params)
    if @project.save
      redirect_to @project, notice: "Project was successfully created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def project_params
    params.require(:project).permit(:name, :description, :repository_url, :setup_script, :repo_path, :dev_dockerfile, :dev_container_port)
  end

  def update_project_secrets
    secrets_json = params[:project][:secrets]
    return if secrets_json.blank?

    begin
      secrets_hash = JSON.parse(secrets_json)
      @project.update_secrets(secrets_hash)
    rescue JSON::ParserError
      flash[:alert] = "Invalid JSON format for secrets"
    end
  end
end
