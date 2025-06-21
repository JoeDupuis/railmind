class AddDevContainerPortToProjects < ActiveRecord::Migration[8.0]
  def change
    add_column :projects, :dev_container_port, :integer, default: 3000
  end
end
