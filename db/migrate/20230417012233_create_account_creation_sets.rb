class CreateAccountCreationSets < ActiveRecord::Migration[7.0]
  def change
    create_table :account_creation_sets do |t|

      t.timestamps
    end
  end
end
