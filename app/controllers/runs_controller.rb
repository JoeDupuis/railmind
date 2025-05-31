class RunsController < ApplicationController
  before_action :set_project_and_task

  def create
    @run = @task.runs.build(run_params)

    respond_to do |format|
      if @run.save
        RunJob.perform_later(@run.id)
        format.turbo_stream
        format.html { redirect_to project_task_path(@project, @task), notice: "Run started successfully." }
      else
        format.turbo_stream { redirect_to project_task_path(@project, @task), alert: "Failed to start run: #{@run.errors.full_messages.join(', ')}" }
        format.html { redirect_to project_task_path(@project, @task), alert: "Failed to start run: #{@run.errors.full_messages.join(', ')}" }
      end
    end
  end

  private

  def set_project_and_task
    @project = Project.find(params[:project_id])
    @task = @project.tasks.find(params[:task_id])
  end

  def run_params
    params.require(:run).permit(:prompt)
  end
end
