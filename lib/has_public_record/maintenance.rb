# frozen_string_literal: true

module HasPublicRecord
  # What the rake tasks do, kept here so it can be tested and called from a console or a deploy script.
  module Maintenance
    Report = Data.define(:model, :table, :column, :total, :missing, :wrong_prefix, :wrong_samples, :duplicates, :problem) do
      def ok? = problem.nil? && missing.zero? && wrong_prefix.zero? && duplicates.zero?
    end

    # How full a table's code space is. Growth starts well before 100%: at half full, one random try in two hits
    # a taken code, so ten tries in a row fail about once in a thousand.
    Capacity = Data.define(:length, :slots, :used) do
      def fill = used.fdiv(slots)

      def to_s
        "#{length} chars = #{ActiveSupport::NumberHelper.number_to_human(slots)} ids, #{format('%.4f', fill * 100)}% used"
      end
    end

    class << self
      # Every model that declared has_public_record (base classes only, so STI subclasses are not listed twice).
      # only: accepts "User", "user" or "users" (also "billing/invoice").
      def models(only: nil)
        found = ActiveRecord::Base.descendants.select do |model|
          model.respond_to?(:public_record_options) && model.public_record_options && model.name.present? &&
            !model.abstract_class? && model == model.base_class
        end.sort_by(&:to_s)
        return found unless only

        names = name_variants(only)
        found.select { |model| names.include?(model.name) }
      end

      # Like models, but raises HasPublicRecord::Error when nothing matches (the rake tasks turn that into an abort).
      def models!(only: nil)
        found = models(only: only)
        return found unless found.empty?

        raise Error, only ? "No model named #{only} declares has_public_record." : "No model declares has_public_record."
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

      def capacity(model)
        length = Generator.starting_length(model.table_name, model.public_record_options.length)
        used = model.base_class.unscoped.where.not(model.public_id_column => [nil, ""]).count
        Capacity.new(length: length, slots: HasPublicRecord.config.alphabet.size**length, used: used)
      end

      # Moves stored ids from an old prefix to the model's declared one (change prefix: in the model first).
      # Counts only unless apply: true (the count is then an estimate from the database). One transaction: all rows
      # move or none do. Returns the rows actually changed.
      def rename_prefix(model, from:, apply: false, batch_size: 1000)
        from = from.to_s
        to = model.public_id_prefix
        raise ArgumentError, "invalid prefix #{from.inspect}" unless PREFIX_FORMAT.match?(from)
        raise ArgumentError, "#{from.inspect} is already the prefix #{model.name} declares" if from == to

        column = model.public_id_column
        old = "#{from}#{SEPARATOR}"
        scope = model.base_class.unscoped.where(with_prefix(model, old))
        return scope.count unless apply

        renamed = 0
        model.transaction do
          scope.find_each(batch_size: batch_size) do |record|
            current = record[column]
            next unless current.start_with?(old) # the LIKE may be case-insensitive on some databases

            renamed += model.public_record_row_scope(record).update_all(column => "#{to}#{SEPARATOR}#{current.delete_prefix(old)}")
          end
        end
        ActiveSupport::Notifications.instrument("rename.has_public_record",
                                                table: model.table_name, column: column, from: from, to: to, count: renamed)
        renamed
      end

      private

      def name_variants(only)
        text = only.to_s.strip
        [text, text.camelize, text.singularize.camelize].uniq
      end

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
