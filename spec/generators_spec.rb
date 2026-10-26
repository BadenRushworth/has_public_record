# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "stringio"
require "tmpdir"
require "rails"
require "rails/generators"
require "generators/has_public_record/install/install_generator"
require "generators/has_public_record/migration/migration_generator"

RSpec.describe "generators" do
  around do |example|
    root = File.expand_path("../tmp", __dir__)
    FileUtils.mkdir_p(root)
    Dir.mktmpdir("gen", root) do |dir|
      @dir = dir
      example.run
    end
  end

  def run_generator(generator, args)
    original = $stdout
    $stdout = StringIO.new
    generator.start(args, destination_root: @dir)
  ensure
    $stdout = original
  end

  def migrations = Dir[File.join(@dir, "db/migrate/*.rb")].sort

  describe HasPublicRecord::Generators::InstallGenerator do
    it "writes an initializer that shows the real defaults, all commented out" do
      run_generator(described_class, [])
      text = File.read(File.join(@dir, "config/initializers/has_public_record.rb"))

      expect(text).to include("HasPublicRecord.configure do |config|")
      expect(text).to include("# config.default_length = 6")
      expect(text).to include("# config.alphabet = \"#{HasPublicRecord::Configuration::DEFAULT_ALPHABET}\"")
      expect(text.lines.grep(/^\s*config\./)).to be_empty
    end
  end

  describe HasPublicRecord::Generators::MigrationGenerator do
    it "adds a nullable column and a unique index" do
      run_generator(described_class, ["users"])
      expect(migrations.size).to eq(1)
      expect(migrations.first).to match(/add_public_id_to_users\.rb\z/)

      text = File.read(migrations.first)
      expect(text).to include("add_column :users, :public_id, :string")
      expect(text).to include("add_index :users, :public_id, unique: true")
      expect(text).not_to include("adapter_name")
    end

    it "takes a column name, and uses the table name as given" do
      run_generator(described_class, ["status", "--column=slug"])
      expect(migrations.first).to match(/add_slug_to_status\.rb\z/)
      expect(File.read(migrations.first)).to include("add_column :status, :slug, :string")
    end

    it "makes the column NOT NULL with --enforce" do
      run_generator(described_class, ["users", "--enforce"])
      expect(migrations.first).to match(/enforce_public_id_on_users\.rb\z/)
      expect(File.read(migrations.first)).to include("change_column_null :users, :public_id, false")
    end

    it "asks for a concurrent index only on PostgreSQL with --concurrently" do
      run_generator(described_class, ["users", "--concurrently"])
      text = File.read(migrations.first)

      expect(text).to include("disable_ddl_transaction!")
      expect(text).to include("adapter_name.match?(/postgres/i)")
      expect(text).to include("algorithm] = :concurrently")
    end
  end
end
