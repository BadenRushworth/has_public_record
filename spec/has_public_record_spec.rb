# frozen_string_literal: true

require "spec_helper"

RSpec.describe HasPublicRecord do
  describe "a model with has_public_record" do
    it "gets a prefixed id of the configured length on create" do
      expect(User.create!.public_id).to match(/\Ausr_[0-9A-Z]{6}\z/)
    end

    it "uses the model's own length: option" do
      expect(Widget.create!.public_id).to match(/\Awid_[0-9A-Z]{4}\z/)
    end

    it "lets config.lengths beat the model option" do
      HasPublicRecord.config.lengths = { widgets: 9 }
      expect(Widget.create!.public_id).to match(/\Awid_[0-9A-Z]{9}\z/)
    end

    it "keeps an id that was supplied" do
      expect(User.create!(public_id: "usr_MINE01").public_id).to eq("usr_MINE01")
    end

    it "refuses an id carrying another model's prefix" do
      user = User.new(public_id: "wid_AAAAAA")
      expect(user).not_to be_valid
      expect(user.errors).to include(:public_id)
    end

    it "keeps its id when other attributes change" do
      user = User.create!
      expect { user.update!(name: "x") }.not_to(change { user.reload.public_id })
    end
  end

  describe "convenience methods" do
    let!(:user) { User.create! }

    it "to_param is nil until saved, then the public id" do
      expect(User.new.to_param).to be_nil
      expect(user.to_param).to eq(user.public_id)
    end

    it "public_id_bare strips the prefix" do
      expect(user.public_id_bare).to eq(user.public_id.delete_prefix("usr_"))
      expect(user.public_id_prefix).to eq("usr")
    end

    it "finds by prefixed or bare id" do
      expect(User.find_by_public_id(user.public_id)).to eq(user)
      expect(User.find_by_public_id(user.public_id_bare)).to eq(user)
    end

    it "ignores ids of another model and junk" do
      expect(User.find_by_public_id("wid_#{user.public_id_bare}")).to be_nil
      expect(User.find_by_public_id(nil)).to be_nil
      expect(User.find_by_public_id("  ")).to be_nil
    end

    it "find_by_public_id! raises RecordNotFound" do
      expect { User.find_by_public_id!("usr_NOPE00") }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "with_public_id returns a relation for many ids" do
      other = User.create!
      expect(User.with_public_id(user.public_id, other.public_id_bare, "wid_X")).to contain_exactly(user, other)
    end

    it "public_id? says whether an id belongs to the model" do
      expect(User.public_id?("usr_ABC123")).to be(true)
      expect(User.public_id?("wid_ABC123")).to be(false)
    end

    it "prefix and column readers" do
      expect(User.public_id_prefix).to eq("usr")
      expect(User.public_id_column).to eq(:public_id)
    end
  end

  describe "backfill" do
    it "gives rows without an id one" do
      User.insert_all([{ name: "old" }, { name: "older" }])
      expect(User.missing_public_id.count).to eq(2)
      expect(User.backfill_public_ids!).to eq(2)
      expect(User.missing_public_id.count).to eq(0)
      expect(User.pluck(:public_id)).to all(match(/\Ausr_/))
    end
  end

  describe "resolving refs" do
    let!(:user) { User.create! }

    it "finds the record from a ref alone" do
      expect(described_class.resolve(user.public_id)).to eq(user)
      expect(described_class.model_for(user.public_id)).to eq(User)
    end

    it "returns nil for unknown prefixes and junk, and resolve! raises" do
      expect(described_class.resolve("zzz_ABC123")).to be_nil
      expect(described_class.resolve("nonsense")).to be_nil
      expect { described_class.resolve!("zzz_ABC123") }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "parses refs" do
      expect(described_class.parse("usr_K3F9A2")).to have_attributes(prefix: "usr", bare: "K3F9A2")
      expect(described_class.valid?("nope")).to be(false)
    end

    it "lists the declared prefixes" do
      expect(described_class.prefixes).to include("usr" => "User", "wid" => "Widget")
      expect(described_class.prefix_for(User)).to eq("usr")
    end
  end

  describe HasPublicRecord::Registry do
    subject(:registry) { described_class.new }

    it "treats the same prefix from the same class as a reload" do
      registry.register("abc", "Thing")
      expect { registry.register("abc", "Thing") }.not_to raise_error
    end

    it "refuses a prefix used by another class" do
      registry.register("abc", "Thing")
      expect { registry.register("abc", "Other") }.to raise_error(HasPublicRecord::DuplicatePrefixError, /Thing/)
    end

    it "refuses badly shaped prefixes" do
      ["", "A", "1ab", "a_b", "abcdefghijk"].each do |bad|
        expect { registry.register(bad, "Thing") }.to raise_error(HasPublicRecord::InvalidPrefixError)
      end
    end
  end

  describe HasPublicRecord::Generator do
    let(:scope) do
      Class.new do
        def table_name = "things"
        def exists?(conditions) = conditions.values.first.length < 12 # bare part must reach 8
      end.new
    end

    it "grows the length when codes are dense, announces it, and remembers it" do
      events = []
      sub = ActiveSupport::Notifications.subscribe(described_class::EVENT) { |*, payload| events << payload }

      first = described_class.generate(scope: scope, column: :public_id, prefix: "usr")
      second = described_class.generate(scope: scope, column: :public_id, prefix: "usr")

      expect(first.length).to eq(12)
      expect(second.length).to eq(12)
      expect(events.map { |e| [e[:from], e[:to]] }).to eq([[6, 7], [7, 8]]) # second call did not grow again
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    it "raises ExhaustedError past max_bumps" do
      full = Class.new do
        def table_name = "things"
        def exists?(_) = true
      end.new
      expect { described_class.generate(scope: full, column: :public_id, prefix: "usr", max_bumps: 1) }
        .to raise_error(HasPublicRecord::ExhaustedError)
    end
  end

  describe HasPublicRecord::Configuration do
    it "rejects an alphabet with the separator, whitespace or too few characters" do
      config = described_class.new
      expect { config.alphabet = "AB_C" }.to raise_error(ArgumentError)
      expect { config.alphabet = "A B" }.to raise_error(ArgumentError)
      expect { config.alphabet = "AAA" }.to raise_error(ArgumentError)
    end

    it "rejects non-numbers and too-small values" do
      config = described_class.new
      expect { config.default_length = "x" }.to raise_error(ArgumentError)
      expect { config.default_length = 0 }.to raise_error(ArgumentError)
    end
  end
end
