require "test_helper"

class TasksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:one)
    @agent = agents(:one)
    @task = tasks(:one)
    @user = users(:one)
  end

  test "index requires authentication" do
    get project_tasks_url(@project)
    assert_redirected_to new_session_path

    login @user
    get project_tasks_url(@project)
    assert_response :success
  end

  test "new requires authentication" do
    get new_project_task_url(@project)
    assert_redirected_to new_session_path

    login @user
    get new_project_task_url(@project)
    assert_response :success
  end

  test "create requires authentication" do
    post project_tasks_url(@project), params: { task: { agent_id: @agent.id, prompt: "hi" } }
    assert_redirected_to new_session_path

    login @user
    assert_difference([ "Task.count", "Run.count" ]) do
      post project_tasks_url(@project), params: { task: { agent_id: @agent.id, prompt: "hi" } }
    end
    assert_redirected_to task_path(Task.last)
  end

  test "show requires authentication" do
    get task_url(@task)
    assert_redirected_to new_session_path

    login @user
    get task_url(@task)
    assert_response :success
  end

  test "show renders Step::Text with content" do
    login @user
    run = @task.runs.create!(prompt: "test")
    run.steps.create!(type: "Step::Text", content: "Hello world", raw_response: "raw data")

    get task_url(@task)
    assert_response :success
    assert_select "div.step-text.markdown-content p", text: "Hello world"
  end

  test "show renders Step::Init with session initialized message" do
    login @user
    run = @task.runs.create!(prompt: "test")
    run.steps.create!(type: "Step::Init", content: nil, raw_response: '{"type":"system","subtype":"init"}')

    get task_url(@task)
    assert_response :success
    assert_select "div strong", text: "🚀 Session Initialized"
  end

  test "show renders Step::ToolCall with tool call styling" do
    login @user
    run = @task.runs.create!(prompt: "test")
    content = "name: WebFetch\ninputs: {\"url\":\"https://example.com\",\"prompt\":\"What is the title of this webpage?\"}"
    run.steps.create!(type: "Step::ToolCall", content: content, raw_response: '{"type":"assistant"}')

    get task_url(@task)
    assert_response :success
    assert_select "div strong", text: "🔧 Tool Call"
    assert_select "pre", text: content
  end

  test "show renders Step::ToolResult with tool result styling" do
    login @user
    run = @task.runs.create!(prompt: "test")
    run.steps.create!(type: "Step::ToolResult", content: "total 0", raw_response: '{"type":"user"}')

    get task_url(@task)
    assert_response :success
    assert_select "div strong", text: "⚙️ Tool Result"
    assert_select "pre", text: "total 0"
  end

  test "show renders Step::Result with result styling" do
    login @user
    run = @task.runs.create!(prompt: "test")
    run.steps.create!(type: "Step::Result", content: "Task completed successfully", raw_response: '{"type":"result"}')

    get task_url(@task)
    assert_response :success
    assert_select "div.label", text: "✅ Result"
    assert_select "pre.content", text: "Task completed successfully"
  end

  test "show renders Step::Result with error styling when is_error is true" do
    login @user
    run = @task.runs.create!(prompt: "test")
    run.steps.create!(type: "Step::Result", content: "API Error occurred", raw_response: '{"type":"result","is_error":true}')

    get task_url(@task)
    assert_response :success
    assert_select "div.step-result.-error"
    assert_select "div.label", text: "❌ Result (Error)"
    assert_select "pre.content", text: "API Error occurred"
  end

  test "show renders Step::System with system styling" do
    login @user
    run = @task.runs.create!(prompt: "test")
    run.steps.create!(type: "Step::System", content: "System message", raw_response: '{"type":"system"}')

    get task_url(@task)
    assert_response :success
    assert_select "div strong", text: "🔧 System"
    assert_select "pre", text: "System message"
  end

  test "show renders base Step with raw_response when no STI type" do
    login @user
    run = @task.runs.create!(prompt: "test")
    run.steps.create!(content: "some content", raw_response: "fallback raw data")

    get task_url(@task)
    assert_response :success
    assert_select "pre", text: "fallback raw data"
  end

  test "show displays only last run by default" do
    login @user
    new_run = @task.runs.create!(prompt: "newest run", created_at: Time.current)

    get task_url(@task)
    assert_response :success

    assert_includes response.body, "newest run"
    assert_not_includes response.body, "echo hello"
  end

  test "show displays all runs when show_all_runs parameter is true" do
    login @user
    new_run = @task.runs.create!(prompt: "newest run", created_at: Time.current)

    get task_url(@task, show_all_runs: true)
    assert_response :success

    assert_includes response.body, "newest run"
    assert_includes response.body, "echo hello"
    assert_includes response.body, "echo world"
  end

  test "show displays correct toggle button text when multiple runs exist" do
    login @user
    @task.runs.create!(prompt: "test run")

    get task_url(@task)
    assert_response :success
    assert_select "a", text: "Show All Runs"

    get task_url(@task, show_all_runs: true)
    assert_response :success
    assert_select "a", text: "Show Last Run Only"
  end

  test "show does not display toggle button when only one run exists" do
    login @user
    @task.runs.destroy_all
    @task.runs.create!(prompt: "single run")

    get task_url(@task)
    assert_response :success
    assert_select "a", text: "Show All Runs", count: 0
    assert_select "a", text: "Show Last Run Only", count: 0
  end

  test "destroy requires authentication" do
    delete task_url(@task)
    assert_redirected_to new_session_path

    login @user
    assert_difference("Task.kept.count", -1) do
      delete task_url(@task)
    end
    assert_redirected_to project_tasks_path(@project)
    assert @task.reload.discarded?
  end

  test "show task with run containing diff" do
    login @user
    # Create a run with a diff
    run = @task.runs.create!(prompt: "Test prompt", status: :completed)
    step = run.steps.create!(
      raw_response: "Repository state captured",
      type: "Step::System",
      content: "Repository state captured"
    )
    repo_state = step.repo_states.create!(
      uncommitted_diff: "diff --git a/test.rb b/test.rb\nindex 0000000..1234567 100644\n--- /dev/null\n+++ b/test.rb\n@@ -0,0 +1,3 @@\n+def hello\n+  puts 'Hello, World!'\n+end",
      repository_path: "/test/path"
    )

    get task_url(@task)
    assert_response :success
    assert_select "##{dom_id(run)}"
    assert_select "[data-controller='diff']"
    # Check that the diff text is properly escaped
    assert_match(/data-diff-diff-text-value/, response.body)
  end
end
