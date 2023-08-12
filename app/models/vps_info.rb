class VpsInfo < ApplicationRecord
  has_many :swipe_jobs, dependent: :destroy

  before_destroy :cancel_swipe_jobs

  def self.status_checker_vps(user)
    VpsInfo.where(:user_id => user.id, :ip => '65.108.236.215')[0]
  end

  def cancel_swipe_jobs
    swipe_jobs.each(&:cancel!)
  end

  belongs_to :user
  belongs_to :schedule, optional: true

  def k8s
    K8sAccount.new(self)
  end
  
end
