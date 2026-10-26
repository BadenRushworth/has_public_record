# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module HasPublicRecord
  module Generators
    # rails g has_public_record:migration users            adds the nullable column and its unique index
    # rails g has_public_record:migration users --enforce  later: makes it NOT NULL, once every row has an id
    class MigrationGenerator < ActiveRecord::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Adds a public id column to an existing table (give the table name, e.g. users)."

      class_option :column, type: :string, default: "public_id", desc: "Column name"
      class_option :enforce, type: :boolean, default: false, desc: "Make the column NOT NULL (run after the backfill)"
      class_option :concurrently, type: :boolean, default: false,
                                  desc: "Build the index without locking writes (PostgreSQL; elsewhere it is built normally)"

      def create_migration_file
        migration_template(options[:enforce] ? "enforce.rb.tt" : "add.rb.tt",
                           File.join(db_migrate_path, "#{migration_name}.rb"))
      end

      private

      # The name as given: Rails would pluralize it ("status" -> "statuses").
      def table_name = name.to_s

      def public_column = options[:column]

      def migration_name
        options[:enforce] ? "enforce_#{public_column}_on_#{table_name}" : "add_#{public_column}_to_#{table_name}"
      end
    end
  end
end
