class AddVpsInfoToSwipeJobs < ActiveRecord::Migration[7.0]
  def change
    add_reference :swipe_jobs, :vps_info, index: true, foreign_key: true, null: true
  end
end
