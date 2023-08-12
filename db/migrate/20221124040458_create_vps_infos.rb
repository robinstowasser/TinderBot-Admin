class CreateVpsInfos < ActiveRecord::Migration[7.0]
  def change
    create_table :vps_infos do |t|
      # t.string :profile_name, null: false
      # t.datetime :created_date, null: false
      t.string :ip, null: false
      t.references :user, null: false, foreign_key: true
      t.timestamps
    end
  end
end
