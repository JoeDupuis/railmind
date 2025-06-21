class AddDockerContainerInfoToTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :tasks, :container_id, :string
    add_column :tasks, :container_name, :string
    add_column :tasks, :container_status, :string
    add_column :tasks, :docker_image_id, :string
  end
end
