# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2025_06_21_075133) do
  create_table "agent_specific_settings", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.string "type", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "type"], name: "index_agent_specific_settings_on_agent_id_and_type", unique: true
    t.index ["agent_id"], name: "index_agent_specific_settings_on_agent_id"
  end

  create_table "agents", force: :cascade do |t|
    t.string "name"
    t.string "docker_image"
    t.json "start_arguments"
    t.json "continue_arguments"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "docker_host"
    t.string "log_processor", default: "Text"
    t.string "workplace_path"
    t.json "env_variables"
    t.datetime "discarded_at"
    t.integer "user_id", default: 1000, null: false
    t.string "instructions_mount_path"
    t.string "ssh_mount_path"
    t.string "home_path"
    t.string "mcp_sse_endpoint"
    t.index ["discarded_at"], name: "index_agents_on_discarded_at"
  end

  create_table "projects", force: :cascade do |t|
    t.string "name"
    t.text "description"
    t.string "repository_url"
    t.text "setup_script"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "discarded_at"
    t.string "repo_path"
    t.index ["discarded_at"], name: "index_projects_on_discarded_at"
  end

  create_table "repo_states", force: :cascade do |t|
    t.text "uncommitted_diff"
    t.text "target_branch_diff"
    t.string "repository_path"
    t.integer "step_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["step_id"], name: "index_repo_states_on_step_id"
  end

  create_table "runs", force: :cascade do |t|
    t.integer "task_id", null: false
    t.text "prompt"
    t.integer "status", default: 0, null: false
    t.datetime "started_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["task_id"], name: "index_runs_on_task_id"
  end

  create_table "secrets", force: :cascade do |t|
    t.integer "project_id", null: false
    t.string "key", null: false
    t.text "value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "key"], name: "index_secrets_on_project_id_and_key", unique: true
    t.index ["project_id"], name: "index_secrets_on_project_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "steps", force: :cascade do |t|
    t.integer "run_id", null: false
    t.json "raw_response"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "type"
    t.text "content"
    t.integer "tool_call_id"
    t.string "tool_use_id"
    t.decimal "cost_usd", precision: 10, scale: 8
    t.integer "input_tokens"
    t.integer "output_tokens"
    t.integer "cache_creation_tokens"
    t.integer "cache_read_tokens"
    t.index ["run_id", "tool_use_id"], name: "index_steps_on_run_id_and_tool_use_id"
    t.index ["run_id"], name: "index_steps_on_run_id"
    t.index ["tool_call_id"], name: "index_steps_on_tool_call_id"
    t.index ["type"], name: "index_steps_on_type"
  end

  create_table "tasks", force: :cascade do |t|
    t.integer "project_id", null: false
    t.integer "agent_id", null: false
    t.string "status"
    t.datetime "started_at"
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "discarded_at"
    t.integer "user_id", null: false
    t.boolean "auto_push_enabled", default: false, null: false
    t.string "auto_push_branch"
    t.string "description"
    t.string "target_branch"
    t.index ["agent_id"], name: "index_tasks_on_agent_id"
    t.index ["discarded_at"], name: "index_tasks_on_discarded_at"
    t.index ["project_id"], name: "index_tasks_on_project_id"
    t.index ["user_id"], name: "index_tasks_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "role"
    t.text "github_token"
    t.text "instructions"
    t.text "ssh_key"
    t.text "git_config"
    t.boolean "allow_github_token_access", default: true, null: false
    t.boolean "shrimp_mode", default: true, null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  create_table "volume_mounts", force: :cascade do |t|
    t.integer "volume_id"
    t.integer "task_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "volume_name"
    t.index ["task_id"], name: "index_volume_mounts_on_task_id"
    t.index ["volume_id"], name: "index_volume_mounts_on_volume_id"
  end

  create_table "volumes", force: :cascade do |t|
    t.string "name"
    t.string "path"
    t.integer "agent_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "external", default: false
    t.string "external_name"
    t.index ["agent_id"], name: "index_volumes_on_agent_id"
  end

  add_foreign_key "agent_specific_settings", "agents"
  add_foreign_key "repo_states", "steps"
  add_foreign_key "runs", "tasks"
  add_foreign_key "secrets", "projects"
  add_foreign_key "sessions", "users"
  add_foreign_key "steps", "runs"
  add_foreign_key "tasks", "agents"
  add_foreign_key "tasks", "projects"
  add_foreign_key "tasks", "users"
  add_foreign_key "volume_mounts", "tasks"
  add_foreign_key "volume_mounts", "volumes"
  add_foreign_key "volumes", "agents"
end
