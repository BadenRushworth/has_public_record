# frozen_string_literal: true

require "active_record"
require "has_public_record"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users do |t|
    t.string :public_id
    t.string :name
    t.timestamps
  end
  add_index :users, :public_id, unique: true

  create_table :widgets do |t|
    t.string :public_id
    t.timestamps
  end
  add_index :widgets, :public_id, unique: true
end

class User < ActiveRecord::Base
  has_public_record prefix: "usr"
end

class Widget < ActiveRecord::Base
  has_public_record prefix: "wid", length: 4
end

# STI-style subclass: shares User's table and prefix.
class Admin < User; end

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.after do
    HasPublicRecord.config.reset!
    HasPublicRecord::Generator.reset_learned!
    User.delete_all
    Widget.delete_all
  end
end
