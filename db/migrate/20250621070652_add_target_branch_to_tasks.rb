class AddTargetBranchToTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :tasks, :target_branch, :string
  end
end
