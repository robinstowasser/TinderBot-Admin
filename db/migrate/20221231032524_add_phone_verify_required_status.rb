class AddPhoneVerifyRequiredStatus < ActiveRecord::Migration[7.0]
  def change
    execute <<-SQL
      ALTER TYPE tinder_account_status ADD VALUE 'phone_verify_required';
    SQL
  end
end
