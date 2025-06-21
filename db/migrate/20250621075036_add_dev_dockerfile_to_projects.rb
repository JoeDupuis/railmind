class AddDevDockerfileToProjects < ActiveRecord::Migration[8.0]
  def change
    add_column :projects, :dev_dockerfile, :text
  end
end
