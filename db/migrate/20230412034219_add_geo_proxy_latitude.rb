class AddGeoProxyLatitude < ActiveRecord::Migration[7.0]
  def change
    add_column :tinder_accounts, :geo_proxy_latitude, :decimal
  end
end
