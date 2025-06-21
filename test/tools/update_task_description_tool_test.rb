require "test_helper"

class UpdateTaskDescriptionToolTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @project = projects(:one)
    @agent = agents(:one)
    @task = Task.create!(
      description: "Original description",
      project: @project,
      agent: @agent,
      user: @user
    )
    @tool = UpdateTaskDescriptionTool.new
  end

  test "updates task description successfully" do
    result = @tool.call(task_id: @task.id, description: "Updated description")

    assert result[:success]
    assert_equal @task.id, result[:task_id]
    assert_equal "Updated description", result[:description]
    assert_equal "Task description updated successfully", result[:message]

    @task.reload
    assert_equal "Updated description", @task.description
  end

  test "returns error when task not found" do
    result = @tool.call(task_id: 99999, description: "New description")

    assert_not result[:success]
    assert_equal "Task not found with ID: 99999", result[:error]
  end

  test "handles empty description validation error" do
    result = @tool.call(task_id: @task.id, description: "")

    assert_not result[:success]
    assert result[:errors].include?("Description can't be blank")
    assert_equal "Failed to update task description", result[:message]
  end

  test "handles unexpected errors gracefully" do
    Task.stub :find_by, ->(_) { raise StandardError, "Database error" } do
      result = @tool.call(task_id: @task.id, description: "New description")

      assert_not result[:success]
      assert_equal "Database error", result[:error]
      assert_equal "An error occurred while updating the task description", result[:message]
    end
  end
end