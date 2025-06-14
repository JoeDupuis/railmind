class TasksController < ApplicationController
  before_action :set_project
  before_action :set_task, only: [ :show, :destroy, :branches, :update_auto_push ]

  def index
    @tasks = @project.tasks.kept.includes(:agent, :project)
  end

  def show
    @show_all_runs = params[:show_all_runs] == "true"
    @selected_run = if params[:selected_run_id].present?
      @task.runs.find_by(id: params[:selected_run_id])
    else
      @task.runs.order(created_at: :desc).first
    end
    if @show_all_runs
      @runs = @task.runs.includes(steps: :repo_states).order(created_at: :asc)
    else
      @runs = @selected_run ? [ @selected_run ] : []
    end
  end

  def new
    @task = @project.tasks.new
    @task.agent_id = cookies[:preferred_agent_id] if cookies[:preferred_agent_id].present?
    @task.project_id = cookies[:preferred_project_id] if cookies[:preferred_project_id].present?
  end

  def create
    @task = Task.new(task_params.with_defaults(project_id: @project&.id, user_id: Current.user.id))

    if @task.save
      cookies[:preferred_agent_id] = { value: @task.agent_id, expires: 1.year.from_now }
      cookies[:preferred_project_id] = { value: @task.project_id, expires: 1.year.from_now }
      @task.update!(started_at: Time.current)
      @task.run(params[:task][:prompt])
      redirect_to task_path(@task), notice: "Task was successfully launched."
    else
      if @project.present?
        render :new, status: :unprocessable_entity
      else
        @tasks = Task.kept.includes(:agent, :project).order(created_at: :desc)
        @projects = Project.kept
        @agents = Agent.kept
        render "dashboard/index", status: :unprocessable_entity
      end
    end
  end

  def destroy
    @task.discard
    redirect_to project_tasks_path(@task.project), notice: "Task was successfully archived."
  end

  def branches
    @branches = @task.fetch_branches
    Rails.logger.info "Fetched branches from controller: #{@branches.inspect}"
    render turbo_stream: turbo_stream.replace("branch_select_container",
                                              partial: "tasks/branch_select",
                                              locals: { task: @task, branches: @branches })
  rescue => e
    Rails.logger.error "Branch fetch error: #{e.message}"
    flash.now[:alert] = "Failed to fetch branches: #{e.message}"
    render turbo_stream: turbo_stream.prepend("flash-messages", partial: "application/flash_messages")
  end

  def update_auto_push
    auto_push_enabled = params[:task][:auto_push_branch].present?

    if @task.update(auto_push_branch: params[:task][:auto_push_branch], auto_push_enabled: auto_push_enabled)
      if @task.auto_push_enabled? && @task.auto_push_branch.present?
        begin
          @task.push_changes_to_branch
          flash.now[:notice] = "Auto-push settings saved and changes pushed to #{@task.auto_push_branch}"
        rescue => e
          flash.now[:alert] = "Settings saved but push failed: #{e.message}"
        end
      else
        flash.now[:notice] = "Auto-push settings saved"
      end

      render turbo_stream: [
        turbo_stream.replace("auto_push_form", partial: "tasks/auto_push_form", locals: { task: @task }),
        turbo_stream.prepend("flash-messages", partial: "application/flash_messages")
      ]
    else
      render json: { error: @task.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end

  private

  def set_project
    @project = Project.find(params[:project_id]) if params[:project_id].present?
  end

  def set_task
    if @project.present?
      @task = @project.tasks.find(params[:id])
    else
      @task = Task.find(params[:id])
    end
  end

  def task_params
    params.require(:task).permit(:agent_id, :project_id)
  end

  def auto_push_params
    params.require(:task).permit(:auto_push_enabled, :auto_push_branch)
  end
end
