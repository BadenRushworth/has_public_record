# frozen_string_literal: true

module HasPublicRecord
  # What the rake tasks do, kept here so it can be tested and called from a console or a deploy script.
  module Maintenance
    Report = Data.define(:model, :table, :column, :total, :missing, :wrong_prefix, :wrong_samples, :duplicates, :problem) do
      def ok? = problem.nil? && missing.zero? && wrong_prefix.zero? && duplicates.zero?
    end

    class << self
      # Every model that declared has_public_record (one per table and column), optionally only the named one.
      def models(only: nil)
        found = ActiveRecord::Base.descendants.select do |model|
          model.respond_to?(:public_record_options) && model.public_record_options && !model.abstract_class?
        end
        found = found.uniq { |model| [model.table_name, model.public_id_column] }.sort_by(&:to_s)
        only ? found.select { |model| model.name == only.to_s } : found
      end

      def reports(only: nil) = models(only: only).map { |model| report(model) }

      # Rows without an id, rows whose id does not start with this model's prefix (legacy bare codes, or another
      # model's prefix), and duplicated ids (only possible when the unique index is missing).
      def report(model)
        table = model.table_name
        column = model.public_id_column
        return broken(model, "table #{table} does not exist") unless model.table_exists?
        unless model.column_names.include?(column.to_s)
          return broken(model, "column #{column} is missing: rails g has_public_record:migration #{table}")
        end

        scope = model.base_class.unscoped
        present = scope.where.not(column => [nil, ""])
        wrong = present.where.not(with_prefix(model))
        Report.new(model: model, table: table, column: column, total: scope.count,
                   missing: scope.where(column => [nil, ""]).count,
                   wrong_prefix: wrong.count, wrong_samples: wrong.limit(3).pluck(column),
                   duplicates: present.group(column).having("COUNT(*) > 1").count.size, problem: nil)
      end

      # Moves stored ids from an old prefix to the model's declared one (change prefix: in the model first).
      # Counts only unless apply: true. One transaction: all rows move or none do. Returns the rows concerned.
      def rename_prefix(model, from:, apply: false, batch_size: 1000)
        from = from.to_s
        to = model.public_id_prefix
        raise ArgumentError, "invalid prefix #{from.inspect}" unless PREFIX_FORMAT.match?(from)
        raise ArgumentError, "#{from.inspect} is already the prefix #{model.name} declares" if from == to

        column = model.public_id_column
        old = "#{from}#{SEPARATOR}"
        scope = model.base_class.unscoped.where(with_prefix(model, old))
        count = scope.count
        return count unless apply && count.positive?

        model.transaction do
          scope.find_each(batch_size: batch_size) do |record|
            next unless record[column].start_with?(old) # the LIKE may be case-insensitive on some databases

            renamed = "#{to}#{SEPARATOR}#{record[column].delete_prefix(old)}"
            model.public_record_row_scope(record).update_all(column => renamed)
          end
        end
        ActiveSupport::Notifications.instrument("rename.has_public_record",
                                                table: model.table_name, column: column, from: from, to: to, count: count)
        count
      end

      private

      def broken(model, problem)
        Report.new(model: model, table: model.table_name, column: model.public_id_column, total: 0, missing: 0,
                   wrong_prefix: 0, wrong_samples: [], duplicates: 0, problem: problem)
      end

      # column LIKE 'usr\_%' with the underscore escaped (it is a wildcard in LIKE).
      def with_prefix(model, text = "#{model.public_id_prefix}#{SEPARATOR}")
        model.base_class.arel_table[model.public_id_column].matches("#{model.sanitize_sql_like(text)}%", "\\")
      end
    end
  end
end
