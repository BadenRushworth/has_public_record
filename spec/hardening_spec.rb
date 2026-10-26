# frozen_string_literal: true

require "spec_helper"

RSpec.describe "has_public_record 0.1.1" do
  describe "the public id type" do
    it "normalizes what is assigned" do
      expect(User.new(public_id: "usr_k3f9a2").public_id).to eq("usr_K3F9A2")
      expect(User.new(public_id: "K3F9A2").public_id).to eq("usr_K3F9A2")
      expect(User.new(public_id: "  USR_k3f9a2 ").public_id).to eq("usr_K3F9A2")
    end

    it "accepts a lower-case id on create" do
      expect(User.create!(public_id: "usr_abc123").public_id).to eq("usr_ABC123")
    end

    it "normalizes query values, so where and find_by match in any case" do
      user = User.create!
      expect(User.where(public_id: user.public_id.downcase)).to contain_exactly(user)
      expect(User.find_by(public_id: user.public_id_bare)).to eq(user)
    end

    it "rejects characters outside the alphabet, and names the column readably" do
      user = User.new(public_id: "usr_!@\#$%^")
      expect(user).not_to be_valid
      expect(user.errors.full_messages).to include("Public ID is invalid")
      expect(User.new(public_id: "usr_")).not_to be_valid
    end

    it "returns a row exactly as stored, so a legacy bare code stays visible" do
      user = User.create!
      User.connection.execute("UPDATE users SET public_id = 'K3F9A2' WHERE id = #{user.id}")
      expect(User.find(user.id).public_id).to eq("K3F9A2")
    end
  end

  describe "missing ids" do
    it "counts empty strings as missing, so report and backfill agree" do
      user = User.create!
      User.connection.execute("UPDATE users SET public_id = '' WHERE id = #{user.id}")
      expect(User.missing_public_id.count).to eq(1)
      expect(HasPublicRecord::Maintenance.report(User).missing).to eq(1)
      expect(User.backfill_public_ids!).to eq(1)
      expect(User.missing_public_id.count).to eq(0)
    end

    it "backfills in batches with distinct ids" do
      User.insert_all((1..5).map { |n| { name: "u#{n}" } })
      expect(User.backfill_public_ids!(batch_size: 2)).to eq(5)
      expect(User.pluck(:public_id).uniq.size).to eq(5)
    end
  end

  describe "declaration" do
    it "refuses an abstract class" do
      expect do
        Class.new(ActiveRecord::Base) do
          self.abstract_class = true
          def self.name = "AbstractThing"
          has_public_record prefix: "abs"
        end
      end.to raise_error(HasPublicRecord::Error, /abstract/)
      expect(HasPublicRecord.prefixes).not_to have_key("abs")
    end

    it "reset_registry! forgets declarations (until the classes declare themselves again)" do
      before = HasPublicRecord.prefixes
      HasPublicRecord.reset_registry!
      expect(HasPublicRecord.prefixes).to be_empty
    ensure
      before.each { |prefix, name| HasPublicRecord.registry.register(prefix, name) }
    end
  end

  describe "the generator" do
    it "never learns past start + max_bumps, however many calls fail" do
      3.times do
        expect { HasPublicRecord.generate("inv", max_bumps: 1) { false } }.to raise_error(HasPublicRecord::ExhaustedError)
      end
      expect(HasPublicRecord::Generator::LEARNED["inv"]).to eq(7)
    end

    it "generate_public_ids makes distinct ids with one existence query" do
      User.columns
      queries = []
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, p| queries << p[:sql] if p[:name] != "SCHEMA" }

      ids = User.generate_public_ids(50)

      expect(ids.uniq.size).to eq(50)
      expect(ids).to all(match(/\Ausr_[0-9A-Z]{6}\z/))
      expect(queries.grep(/SELECT/).size).to eq(1)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    it "avoids ids that exist and ids the caller reserved" do
      allow(HasPublicRecord::Generator).to receive(:random).and_return("TAKEN1", "RESERV", "FRESH1", "FRESH2")
      User.create!(public_id: "usr_TAKEN1")
      expect(User.generate_public_ids(2, reserved: ["usr_RESERV"])).to eq(%w[usr_FRESH1 usr_FRESH2])
    end
  end

  describe "regenerate_public_id!" do
    it "replaces the id in the database and on the record, without leaving it dirty" do
      user = User.create!
      old = user.public_id
      events = []
      sub = ActiveSupport::Notifications.subscribe("regenerate.has_public_record") { |*, p| events << p }

      fresh = user.regenerate_public_id!

      expect(fresh).to match(/\Ausr_/)
      expect(fresh).not_to eq(old)
      expect(user.public_id).to eq(fresh)
      expect(user).not_to be_changed
      expect(User.find(user.id).public_id).to eq(fresh)
      expect(events.first).to include(table: "users", from: old, to: fresh)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    it "refuses an unsaved record" do
      expect { User.new.regenerate_public_id! }.to raise_error(HasPublicRecord::Error, /saved/)
    end
  end

  describe "maintenance" do
    it "finds models by singular, plural or class name, and says when none match" do
      %w[User user users].each { |name| expect(HasPublicRecord::Maintenance.models(only: name)).to eq([User]) }
      expect { HasPublicRecord::Maintenance.models!(only: "nope") }.to raise_error(HasPublicRecord::Error, /nope/)
    end
  end
end
