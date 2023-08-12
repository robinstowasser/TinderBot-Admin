class AddGeoProxyLongitude < ActiveRecord::Migration[7.0]
  def change
    add_column :tinder_accounts, :geo_proxy_longitude, :decimal
  end
end
