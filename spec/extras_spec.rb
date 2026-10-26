# frozen_string_literal: true

require "spec_helper"

RSpec.describe "has_public_record extras" do
  describe "safety" do
    it "clears the id on dup, so the copy gets its own" do
      user = User.create!
      copy = user.dup
      expect(copy.public_id).to be_nil
      copy.save!
      expect(copy.public_id).to match(/\Ausr_/).and(differ_from(user.public_id))
    end

    it "refuses a second declaration in a subclass" do
      expect { Class.new(User) { has_public_record prefix: "adm" } }
        .to raise_error(HasPublicRecord::Error, /once/)
    end

    it "lists only base classes in the maintenance tools" do
      expect(HasPublicRecord::Maintenance.models).to include(User)
      expect(HasPublicRecord::Maintenance.models).not_to include(Admin)
    end
  end

  describe "lookup helpers" do
    let!(:user) { User.create! }

    it "finds regardless of letter case" do
      expect(User.find_by_public_id(user.public_id.downcase)).to eq(user)
      expect(User.find_by_public_id("USR_#{user.public_id_bare.downcase}")).to eq(user)
      expect(HasPublicRecord.resolve(user.public_id.swapcase)).to eq(user)
    end

    it "leaves a mixed-case alphabet exactly as typed" do
      HasPublicRecord.config.alphabet = "aAbBcC"
      expect(HasPublicRecord.fold_case("aBc")).to eq("aBc")
    end

    it "from_param and from_param! take what a controller has" do
      expect(User.from_param(user.to_param)).to eq(user)
      expect(User.from_param(nil)).to be_nil
      expect { User.from_param!(nil) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "public_id_format matches this model's ids in any case, and nothing else" do
      format = /\A#{User.public_id_format}\z/
      expect(format).to match("usr_K3F9A2")
      expect(format).to match("USR_k3f9a2")
      expect(format).not_to match("wid_K3F9A2")
      expect(format).not_to match("usr_")
    end

    it "resolve_many resolves mixed refs, one query per model" do
      widget = Widget.create!
      queries = []
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, p| queries << p[:name] }

      result = HasPublicRecord.resolve_many(user.public_id, widget.public_id, "zzz_ABC123", "nonsense", user.public_id.downcase)

      expect(result).to eq(user.public_id => user, widget.public_id => widget, user.public_id.downcase => user)
      expect(queries.count { |name| name.to_s.end_with?("Load") }).to eq(2)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end
  end

  describe "testing helpers" do
    it "fixture_id is stable per label and shaped like an id" do
      id = HasPublicRecord.fixture_id("usr", :alice)
      expect(id).to match(/\Ausr_[0-9A-Z]{6}\z/)
      expect(id).to eq(HasPublicRecord.fixture_id("usr", "alice"))
      expect(id).not_to eq(HasPublicRecord.fixture_id("usr", :bob))
      expect(HasPublicRecord.fixture_id(nil, :alice, length: 5)).to match(/\A[0-9A-Z]{5}\z/)
      expect(User.fixture_public_id(:alice)).to eq(id)
    end

    it "with_generated_public_ids fills rows for insert_all and keeps supplied ids" do
      rows = User.with_generated_public_ids([{ name: "a" }, { "name" => "b" }, { name: "c", public_id: "usr_KEEP01" }])
      expect(rows.last[:public_id]).to eq("usr_KEEP01")
      User.insert_all(rows)
      expect(User.count).to eq(3)
      expect(User.missing_public_id.count).to eq(0)
    end

    it "never gives two rows of one batch the same id" do
      allow(HasPublicRecord::Generator).to receive(:random).and_return("DUPLIC", "DUPLIC", "OTHER1", "OTHER2")
      rows = User.with_generated_public_ids([{ name: "a" }, { name: "b" }])
      expect(rows.map { |row| row[:public_id] }).to eq(%w[usr_DUPLIC usr_OTHER1])
    end
  end

  describe "capacity" do
    it "reports the code space and how much is used" do
      User.create!
      capacity = HasPublicRecord::Maintenance.capacity(User)
      expect(capacity).to have_attributes(length: 6, slots: 36**6, used: 1)
      expect(capacity.to_s).to match(/6 chars = .* ids, 0\.0000% used/)
    end

    it "follows config.lengths" do
      HasPublicRecord.config.lengths = { users: 3 }
      expect(HasPublicRecord::Maintenance.capacity(User)).to have_attributes(length: 3, slots: 36**3)
    end
  end

  describe "alphabet presets" do
    it "has an unambiguous preset with no 0, O, 1, I or L" do
      HasPublicRecord.config.alphabet = :unambiguous
      expect(HasPublicRecord.config.alphabet).not_to match(/[01OIL]/)
      expect(User.create!.public_id_bare).to match(/\A[#{HasPublicRecord::Configuration::UNAMBIGUOUS}]{6}\z/)
    end

    it "rejects an unknown preset" do
      expect { HasPublicRecord.config.alphabet = :nope }.to raise_error(ArgumentError, /preset/)
    end
  end

  describe "ids without a model" do
    it "makes an id from a block" do
      expect(HasPublicRecord.generate("inv", length: 8) { true }).to match(/\Ainv_[0-9A-Z]{8}\z/)
    end

    it "makes a bare code when there is no prefix, but needs a key" do
      expect(HasPublicRecord.generate(nil, length: 5, key: "codes") { true }).to match(/\A[0-9A-Z]{5}\z/)
      expect { HasPublicRecord.generate(nil) { true } }.to raise_error(ArgumentError, /key/)
    end

    it "grows and announces it, under the key" do
      events = []
      sub = ActiveSupport::Notifications.subscribe(HasPublicRecord::Generator::EVENT) { |*, payload| events << payload }
      id = HasPublicRecord.generate("inv") { |candidate| candidate.length >= 12 }
      expect(id.length).to eq(12)
      expect(events.map { |e| [e[:key], e[:from], e[:to]] }).to eq([["inv", 6, 7], ["inv", 7, 8]])
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    it "raises ExhaustedError past max_bumps, and InvalidPrefixError for a bad prefix" do
      expect { HasPublicRecord.generate("inv", max_bumps: 1) { false } }.to raise_error(HasPublicRecord::ExhaustedError)
      expect { HasPublicRecord.generate("A!") { true } }.to raise_error(HasPublicRecord::InvalidPrefixError)
    end

    it "still accepts a scope" do
      scope = Class.new { def table_name = "t"; def exists?(_) = false }.new
      expect(HasPublicRecord.generate(scope: scope, column: :public_id, prefix: "usr")).to match(/\Ausr_/)
    end

    describe "identifier" do
      subject(:invoices) { HasPublicRecord.identifier("inv", length: 8) { true } }

      it "generates, validates and strips" do
        id = invoices.generate
        expect(id).to match(/\Ainv_[0-9A-Z]{8}\z/)
        expect(invoices.valid?(id)).to be(true)
        expect(invoices.valid?(id.downcase)).to be(true)
        expect(invoices.valid?("ord_ABC")).to be(false)
        expect(invoices.valid?("")).to be(false)
        expect(invoices.bare(id)).to eq(id.delete_prefix("inv_"))
        expect(invoices.bare("ord_ABC")).to be_nil
      end

      it "refuses a prefix a model declared, and a missing block" do
        expect { HasPublicRecord.identifier("usr") { true } }.to raise_error(HasPublicRecord::DuplicatePrefixError)
        expect { HasPublicRecord::Identifier.new("inv") }.to raise_error(ArgumentError, /block/)
      end
    end
  end

  def differ_from(value) = satisfy { |other| other != value }
end
