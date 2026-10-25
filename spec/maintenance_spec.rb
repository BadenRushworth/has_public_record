# frozen_string_literal: true

require "spec_helper"

RSpec.describe HasPublicRecord::Maintenance do
  describe ".models" do
    it "lists declared models, or one by name" do
      expect(described_class.models).to include(User, Widget)
      expect(described_class.models(only: "User")).to eq([User])
    end
  end

  describe ".report" do
    it "counts missing, wrong-prefix and clean rows" do
      User.create!
      User.insert_all([{ name: "a", public_id: nil }, { name: "b", public_id: "K3F9A2" },
                       { name: "c", public_id: "wid_ABC123" }])

      report = described_class.report(User)
      expect(report).to have_attributes(total: 4, missing: 1, wrong_prefix: 2, duplicates: 0, problem: nil)
      expect(report.wrong_samples).to contain_exactly("K3F9A2", "wid_ABC123")
      expect(report).not_to be_ok
    end

    it "is ok for a clean table" do
      User.create!
      expect(described_class.report(User)).to be_ok
    end

    it "says so when the table is missing" do
      ghost = Class.new(ActiveRecord::Base) do
        self.table_name = "ghosts"
        def self.name = "Ghost"
        has_public_record prefix: "gho"
      end
      expect(described_class.report(ghost).problem).to match(/does not exist/)
    end
  end

  describe ".rename_prefix" do
    before do
      User.insert_all([{ name: "a", public_id: "old_AAAAAA" }, { name: "b", public_id: "old_BBBBBB" },
                       { name: "c", public_id: "usr_CCCCCC" }])
    end

    it "only counts on a dry run" do
      expect(described_class.rename_prefix(User, from: "old")).to eq(2)
      expect(User.pluck(:public_id)).to include("old_AAAAAA", "old_BBBBBB")
    end

    it "renames, and announces it, when applied" do
      events = []
      sub = ActiveSupport::Notifications.subscribe("rename.has_public_record") { |*, payload| events << payload }

      expect(described_class.rename_prefix(User, from: "old", apply: true)).to eq(2)
      expect(User.pluck(:public_id)).to contain_exactly("usr_AAAAAA", "usr_BBBBBB", "usr_CCCCCC")
      expect(events.first).to include(from: "old", to: "usr", count: 2)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    it "moves nothing when one new id would collide" do
      User.insert_all([{ name: "d", public_id: "usr_BBBBBB" }])
      expect { described_class.rename_prefix(User, from: "old", apply: true) }.to raise_error(ActiveRecord::RecordNotUnique)
      expect(User.pluck(:public_id)).to include("old_AAAAAA", "old_BBBBBB")
    end

    it "refuses its own prefix and malformed ones" do
      expect { described_class.rename_prefix(User, from: "usr") }.to raise_error(ArgumentError)
      expect { described_class.rename_prefix(User, from: "A_b") }.to raise_error(ArgumentError)
    end
  end
end
