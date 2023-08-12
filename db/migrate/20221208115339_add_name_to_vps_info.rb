class AddNameToVpsInfo < ActiveRecord::Migration[7.0]
  def change
    add_column :vps_infos, :name, :string
  end
end
