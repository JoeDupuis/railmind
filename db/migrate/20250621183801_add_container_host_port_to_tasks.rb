class AddContainerHostPortToTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :tasks, :container_host_port, :integer
  end
end
