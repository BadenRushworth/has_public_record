# frozen_string_literal: true

require "active_support/concern"

module HasPublicRecord
  module Model
    extend ActiveSupport::Concern

    Options = Data.define(:prefix, :column, :length, :max_bumps)

    included do
      class_attribute :public_record_options, instance_writer: false, instance_predicate: false
    end

    class_methods do
      # Called by the has_public_record macro. Touches no database table, so it is safe while the app boots.
      def declare_public_record(prefix:, column:, length:, max_bumps:)
        if abstract_class?
          raise HasPublicRecord::Error,
                "#{name || inspect}: has_public_record cannot be declared on an abstract class (it has no table); " \
                "declare it on each concrete model"
        end
        if public_record_options
          raise HasPublicRecord::Error,
                "#{name || inspect} already has has_public_record (prefix #{public_record_options.prefix.inspect}); " \
                "declare it once, on the base class"
        end

        prefix = HasPublicRecord.registry.register(prefix, name)
        column = column.to_sym
        self.public_record_options = Options.new(prefix: prefix, column: column, length: length, max_bumps: max_bumps)

        attribute column, HasPublicRecord::PublicIdType.new(prefix: prefix)
        attr_readonly column # a public id never changes once created (regenerate_public_id! is the one way)
        before_create :assign_public_record
        validate :validate_public_record_format, on: :create
      end

      def public_id_prefix = public_record_options.prefix
      def public_id_column = public_record_options.column

      # Rails would call the column "Public" (it strips _id as if it were a foreign key).
      def human_attribute_name(attribute, options = {})
        return super unless public_record_options && attribute.to_s == public_id_column.to_s

        super(attribute, options.merge(default: "Public ID"))
      end

      # The stored form of a ref: "usr_K3F9A2". Accepts the bare code and any letter case (see HasPublicRecord.fold_case).
      # nil for another model's id, for junk and for blank. The alphabet is not checked: ids made under an older
      # alphabet must stay findable.
      def normalize_public_id(ref) = HasPublicRecord.canonicalize(ref, public_id_prefix)

      def public_id?(ref) = !normalize_public_id(ref).nil?

      def find_by_public_id(ref)
        id = normalize_public_id(ref)
        id && find_by(public_id_column => id)
      end

      def find_by_public_id!(ref)
        find_by_public_id(ref) ||
          raise(ActiveRecord::RecordNotFound.new("Couldn't find #{name} with public id #{ref.inspect}", name, public_id_column, ref))
      end

      # What a controller passes in: User.from_param!(params[:id]).
      def from_param(param) = find_by_public_id(param)
      def from_param!(param) = find_by_public_id!(param)

      # A relation for several ids at once; ids of another model are ignored.
      def with_public_id(*refs)
        where(public_id_column => refs.flatten.filter_map { |ref| normalize_public_id(ref) })
      end

      # A regexp for route constraints (no anchors, as Rails wants): resources :users, constraints: { id: User.public_id_format }
      # It follows the CURRENT alphabet: when changing the alphabet, widen it rather than replace it.
      def public_id_format
        alphabet = HasPublicRecord.config.alphabet
        chars = Regexp.escape((alphabet.chars + alphabet.swapcase.chars).uniq.join)
        /(?i:#{Regexp.escape(public_id_prefix)})#{SEPARATOR}[#{chars}]+/
      end

      # Rows that have no public id yet: NULL or an empty string (the report counts both).
      def missing_public_id = where(public_id_column => [nil, ""])

      # A fresh unused id for this model (what before_create uses).
      def generate_public_id
        HasPublicRecord::Generator.generate(scope: base_class.unscoped, column: public_id_column, prefix: public_id_prefix,
                                            length: public_record_options.length, max_bumps: public_record_options.max_bumps)
      end

      # count distinct fresh ids with one existence query instead of one per id. reserved: ids to avoid that are not
      # in the table yet.
      def generate_public_ids(count, reserved: [])
        HasPublicRecord::Generator.generate_many(count, scope: base_class.unscoped, column: public_id_column,
                                                        prefix: public_id_prefix, length: public_record_options.length,
                                                        max_bumps: public_record_options.max_bumps, reserved: reserved)
      end

      # The one row a record is stored in, ignoring default scopes. Handles composite primary keys. A table with no
      # primary key is refused: an empty condition would match every row.
      def public_record_row_scope(record)
        keys = Array(base_class.primary_key)
        raise HasPublicRecord::Error, "#{name} has no primary key, so a single row cannot be addressed" if keys.empty?

        base_class.unscoped.where(keys.zip(Array(record.id)).to_h)
      end

      # Gives every row without an id one; returns how many. One existence query and one transaction per batch.
      # Plain SQL updates: the column is readonly through the model, and callbacks and updated_at stay untouched.
      def backfill_public_ids!(batch_size: 1000)
        count = 0
        missing_public_id.find_in_batches(batch_size: batch_size) do |records|
          ids = generate_public_ids(records.size)
          transaction do
            records.zip(ids) do |record, id|
              count += public_record_row_scope(record).update_all(public_id_column => id)
            end
          end
        end
        count
      end

      # insert_all / upsert_all skip callbacks, so rows get no id. This fills it in (one existence query for the
      # whole batch) and keeps ids you supplied:  User.insert_all(User.with_generated_public_ids(rows))
      def with_generated_public_ids(rows)
        column = public_id_column
        rows = rows.map { |row| row.to_h.symbolize_keys }
        needed = rows.count { |row| row[column].blank? }
        return rows if needed.zero?

        reserved = rows.filter_map { |row| row[column].presence && (normalize_public_id(row[column]) || row[column]) }
        fresh = generate_public_ids(needed, reserved: reserved).each
        rows.map { |row| row[column].present? ? row : row.merge(column => fresh.next) }
      end

      # A stable id for a fixture label, for ERB in fixtures (Rails fixtures skip callbacks):
      #   public_id: <%= User.fixture_public_id(:alice) %>
      def fixture_public_id(label)
        length = HasPublicRecord::Generator.starting_length(table_name, public_record_options.length)
        HasPublicRecord.fixture_id(public_id_prefix, label, length: length)
      end
    end

    # A copy is a new record: it must not carry the original's id into the unique index.
    def initialize_dup(other)
      super
      self[self.class.public_id_column] = nil
    end

    def public_id_prefix = self.class.public_id_prefix

    # "usr_K3F9A2" -> "K3F9A2"
    def public_id_bare
      value = self[self.class.public_id_column]
      value&.delete_prefix("#{public_id_prefix}#{SEPARATOR}")
    end

    # Rails' url helpers use this: user_path(user) -> /users/usr_K3F9A2
    def to_param = (self[self.class.public_id_column] if persisted?)

    # Replaces the id (a leaked link, a rotated invite) and returns the new one. Every old URL stops working.
    # The column stays readonly for everything else.
    def regenerate_public_id!
      raise HasPublicRecord::Error, "#{self.class.name} must be saved before its public id can be regenerated" unless persisted?

      column = self.class.public_id_column
      previous = self[column]
      fresh = self.class.generate_public_id
      if self.class.public_record_row_scope(self).update_all(column => fresh).zero?
        raise ActiveRecord::RecordNotFound, "#{self.class.name} #{id.inspect} no longer exists"
      end

      @attributes.write_from_database(column.to_s, fresh) # not a dirty change, and not an assignment to a readonly column
      ActiveSupport::Notifications.instrument("regenerate.has_public_record",
                                              table: self.class.table_name, column: column, from: previous, to: fresh)
      fresh
    end

    private

    def assign_public_record
      column = self.class.public_id_column
      self[column] = self.class.generate_public_id if self[column].blank?
    end

    # Only ids being created are held to the current alphabet.
    def validate_public_record_format
      column = self.class.public_id_column
      value = self[column]
      return if value.blank? || HasPublicRecord.well_formed?(value, self.class.public_id_prefix)

      errors.add(column, :invalid)
    end
  end
end
