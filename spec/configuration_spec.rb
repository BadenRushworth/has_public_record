# frozen_string_literal: true

require "spec_helper"

RSpec.describe "HasPublicRecord.configure" do
  it "yields the config, applies what is set and returns it" do
    result = HasPublicRecord.configure { |c| c.default_length = 9 }
    expect(result).to be(HasPublicRecord.config)
    expect(User.create!.public_id).to match(/\Ausr_[0-9A-Z]{9}\z/)
  end

  it "reads settings when an id is made, so a later configure still applies" do
    first = User.create!
    HasPublicRecord.configure { |c| c.default_length = 10 }
    expect(first.public_id.length).to eq(10)
    expect(User.create!.public_id.length).to eq(14)
  end

  it "reset! restores every default" do
    HasPublicRecord.config.default_length = 12
    HasPublicRecord.config.lengths = { users: 3 }
    HasPublicRecord.config.reset!
    expect(HasPublicRecord.config).to have_attributes(default_length: 6, lengths: {})
  end

  it "stores table names as strings, whatever they were given as" do
    HasPublicRecord.config.lengths = { users: 8, "widgets" => 5 }
    expect(HasPublicRecord.config.lengths).to eq("users" => 8, "widgets" => 5)
  end
end
