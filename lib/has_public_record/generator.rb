# frozen_string_literal: true

require "securerandom"
require "concurrent/map"

module HasPublicRecord
  # Makes codes. Starts at a length (config.lengths[table] > the model's length: > config.default_length) and grows
  # when random tries keep hitting existing codes, remembering the grown length per table and column (per process).
  # Growth is announced with the "grow.has_public_record" notification (table, column, from, to).
  module Generator
    EVENT = "grow.has_public_record"
    LEARNED = Concurrent::Map.new # [table, column] => length reached after growing

    class << self
      def random(length:, alphabet: HasPublicRecord.config.alphabet)
        chars = alphabet.chars
        Array.new(length) { chars[SecureRandom.random_number(chars.size)] }.join
      end

      # Returns the full public id, prefix included: "usr_K3F9A2".
      def generate(scope:, column:, prefix:, length: nil, max_bumps: nil)
        config = HasPublicRecord.config
        key = [scope.table_name.to_s, column.to_sym]
        limit = max_bumps || config.max_length_bumps
        current = [starting_length(key.first, length), LEARNED[key].to_i].max
        bumps = 0

        loop do
          config.attempts_per_length.times do
            candidate = "#{prefix}#{SEPARATOR}#{random(length: current)}"
            return candidate unless scope.exists?(column => candidate)
          end

          if bumps >= limit
            raise ExhaustedError, "no unique code after #{bumps} length bumps (length #{current}) for #{key.first}.#{key.last}"
          end

          bumps += 1
          from = current
          current += 1
          learn(key, current)
          ActiveSupport::Notifications.instrument(EVENT, table: key.first, column: key.last, from: from, to: current)
        end
      end

      def reset_learned! = LEARNED.clear

      private

      # Atomic per key: a smaller length never overwrites a larger one.
      def learn(key, length) = LEARNED.compute(key) { |learned| [learned.to_i, length].max }

      def starting_length(table, explicit)
        configured = HasPublicRecord.config.lengths[table]
        [Integer(configured || explicit || HasPublicRecord.config.default_length), 1].max
      end
    end
  end
end
