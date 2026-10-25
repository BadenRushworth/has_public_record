# frozen_string_literal: true

require "securerandom"
require "concurrent/map"

module HasPublicRecord
  # Makes codes. Starts at a length (config.lengths[name] > the explicit length > config.default_length) and grows
  # when random tries keep hitting taken codes, remembering the grown length per key (per process). Growth is
  # announced with "grow.has_public_record" (key, table, column, from, to; table and column only for a scope).
  #
  # Whether a code is free is a callable, so nothing here needs a model:
  #   Generator.generate(prefix: "inv", length: 8) { |id| !Redis.exists?(id) }
  #   Generator.generate(prefix: "usr", scope: User.unscoped, column: :public_id)   # what models use
  module Generator
    EVENT = "grow.has_public_record"
    LEARNED = Concurrent::Map.new # key => length reached after growing

    class << self
      def random(length:, alphabet: HasPublicRecord.config.alphabet)
        chars = alphabet.chars
        Array.new(length) { chars[SecureRandom.random_number(chars.size)] }.join
      end

      # Returns the full id ("usr_K3F9A2"), or the bare code when prefix is nil (then key: is required: it names
      # the learned length). The block receives a candidate and answers true when it is free.
      def generate(prefix: nil, length: nil, max_bumps: nil, key: nil, scope: nil, column: nil, &free)
        prefix = check_prefix(prefix)
        free, key, table = source_for(prefix, key, scope, column, free)
        config = HasPublicRecord.config
        limit = max_bumps || config.max_length_bumps
        current = [starting_length(table || key, length), LEARNED[key].to_i].max
        bumps = 0

        loop do
          config.attempts_per_length.times do
            candidate = compose(prefix, random(length: current))
            return candidate if free.call(candidate)
          end

          if bumps >= limit
            raise ExhaustedError, "no unique code after #{bumps} length bumps (length #{current}) for #{key}"
          end

          bumps += 1
          from = current
          current += 1
          learn(key, current)
          ActiveSupport::Notifications.instrument(EVENT, key: key, table: table, column: column, from: from, to: current)
        end
      end

      # The length a name (a table, or a standalone key) starts at.
      def starting_length(name, explicit)
        configured = HasPublicRecord.config.lengths[name.to_s]
        [Integer(configured || explicit || HasPublicRecord.config.default_length), 1].max
      end

      # nil stays nil; anything else must be a well-formed prefix.
      def check_prefix(prefix)
        return nil if prefix.nil?

        text = prefix.to_s
        return text if PREFIX_FORMAT.match?(text)

        raise InvalidPrefixError, "invalid prefix #{text.inspect} (expected #{PREFIX_FORMAT.inspect})"
      end

      def reset_learned! = LEARNED.clear

      private

      def source_for(prefix, key, scope, column, free)
        if scope
          raise ArgumentError, "give a block or scope:, not both" if free
          raise ArgumentError, "scope: needs column:" unless column

          table = scope.table_name.to_s
          [->(candidate) { !scope.exists?(column => candidate) }, (key || "#{table}.#{column}").to_s, table]
        else
          raise ArgumentError, "give a block that says whether an id is free (or scope: and column:)" unless free

          key ||= prefix
          raise ArgumentError, "a generator with no prefix needs key: to name its growth" if key.nil?

          [free, key.to_s, nil]
        end
      end

      def compose(prefix, bare) = prefix ? "#{prefix}#{SEPARATOR}#{bare}" : bare

      # Atomic per key: a smaller length never overwrites a larger one.
      def learn(key, length) = LEARNED.compute(key) { |learned| [learned.to_i, length].max }
    end
  end
end
