class TasksController < ApplicationController
  before_action :set_project, only: [], if: -> { params[:project_id].present? }
  before_action :set_task, only: :show

  def index
    if params[:project_id].present?
      @project = Project.find(params[:project_id])
      @tasks = @project.tasks.includes(:agent, :project)
    else
      @tasks = Task.includes(:agent, :project).order(created_at: :desc)
      @task = Task.new
      @projects = Project.all
      @agents = Agent.all
    end
  end

  def show
    @show_all_runs = params[:show_all_runs] == "true"
    if @show_all_runs
      @runs = @task.runs.order(created_at: :asc)
    else
      @runs = @task.runs.order(created_at: :desc).limit(1)
    end
  end

  def new
    @project = Project.find(params[:project_id])
    @task = @project.tasks.new
    @task.agent_id = cookies[:preferred_agent_id] if cookies[:preferred_agent_id].present?
  end

  def create
    if params[:project_id].present?
      @project = Project.find(params[:project_id])
      @task = @project.tasks.new(task_params)
      redirect_path = [ @project, @task ]
    else
      @task = Task.new(task_params)
      redirect_path = @task
    end

    if @task.save
      cookies[:preferred_agent_id] = { value: @task.agent_id, expires: 1.year.from_now }
      @task.update!(started_at: Time.current)
      @task.run(params[:task][:prompt])
      redirect_to redirect_path, notice: "Task was successfully launched."
    else
      if params[:project_id].present?
        render :new, status: :unprocessable_entity
      else
        @tasks = Task.includes(:agent, :project).order(created_at: :desc)
        @projects = Project.all
        @agents = Agent.all
        render :index, status: :unprocessable_entity
      end
    end
  end

  private

  def set_project
    @project = Project.find(params[:project_id]) if params[:project_id].present?
  end

  def set_task
    if params[:project_id].present?
      @task = Project.find(params[:project_id]).tasks.find(params[:id])
    else
      @task = Task.find(params[:id])
    end
  end

  def task_params
    params.require(:task).permit(:agent_id, :project_id)
  end
end
