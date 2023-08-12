class AddVpsInfoToSchedules < ActiveRecord::Migration[7.0]
  def change
    add_reference :schedules, :vps_info, index: true, foreign_key: true, null: true
  end
end
