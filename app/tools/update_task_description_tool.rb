# frozen_string_literal: true

class UpdateTaskDescriptionTool < ApplicationTool
  description "Update the description of a task"

  arguments do
    required(:task_id).filled(:integer).description("ID of the task to update")
    required(:description).filled(:string).description("New description for the task")
  end

  def call(task_id:, description:)
    task = Task.find_by(id: task_id)

    return { error: "Task not found with ID: #{task_id}" } unless task

    if task.update(description: description)
      {
        success: true,
        task_id: task.id,
        description: task.description,
        message: "Task description updated successfully"
      }
    else
      {
        success: false,
        errors: task.errors.full_messages,
        message: "Failed to update task description"
      }
    end
  rescue StandardError => e
    {
      success: false,
      error: e.message,
      message: "An error occurred while updating the task description"
    }
  end
end