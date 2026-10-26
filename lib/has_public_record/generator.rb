# frozen_string_literal: true

require "securerandom"
require "set"
require "concurrent/map"

module HasPublicRecord
  # Makes codes. Starts at a length (config.lengths[name] > the explicit length > config.default_length) and grows
  # when random tries keep hitting taken codes, remembering the grown length per key (per process). The length never
  # goes past start + max_bumps, so a long outage cannot ratchet it up for good. Growth is announced with
  # "grow.has_public_record" (key, table, column, from, to; table and column only for a scope).
  #
  # Whether a code is free is a callable, so nothing here needs a model:
  #   Generator.generate(prefix: "inv", length: 8) { |id| !Redis.exists?(id) }
  #   Generator.generate(prefix: "usr", scope: User.unscoped, column: :public_id)   # what models use
  module Generator
    EVENT = "grow.has_public_record"
    LEARNED = Concurrent::Map.new # key => length reached after growing
    EXISTS_CHUNK = 500            # candidates per existence query (keeps IN lists inside every database's limits)

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
        start, ceiling = bounds(table || key, length, max_bumps)
        current = start_at(key, start, ceiling)

        loop do
          HasPublicRecord.config.attempts_per_length.times do
            candidate = compose(prefix, random(length: current))
            return candidate if free.call(candidate)
          end
          current = grow(key, table, column, current, start, ceiling)
        end
      end

      # count distinct ids for a scope with ONE existence query per round (per 500 candidates), not one per id.
      # reserved: ids that are not in the database yet but must not be handed out (a batch's supplied ids).
      def generate_many(count, scope:, column:, prefix: nil, length: nil, max_bumps: nil, key: nil, reserved: [])
        prefix = check_prefix(prefix)
        count = Integer(count)
        return [] if count <= 0

        table = scope.table_name.to_s
        key = (key || "#{table}.#{column}").to_s
        start, ceiling = bounds(table, length, max_bumps)
        current = start_at(key, start, ceiling)
        seen = Set.new(reserved.map(&:to_s))
        made = []
        rounds = 0

        while made.size < count
          if rounds >= HasPublicRecord.config.attempts_per_length
            current = grow(key, table, column, current, start, ceiling)
            rounds = 0
          end
          rounds += 1

          candidates = Array.new(count - made.size) { compose(prefix, random(length: current)) }.uniq.reject { |id| seen.include?(id) }
          taken = taken_among(scope, column, candidates)
          candidates.each do |id|
            next if taken.include?(id)

            seen << id
            made << id
          end
        end
        made
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

      # [where this name starts, the longest it may ever get]
      def bounds(name, length, max_bumps)
        start = starting_length(name, length)
        [start, start + (max_bumps || HasPublicRecord.config.max_length_bumps)]
      end

      def start_at(key, start, ceiling) = [[LEARNED[key].to_i, ceiling].min, start].max

      # One step longer, remembered and announced; ExhaustedError once the ceiling is reached.
      def grow(key, table, column, current, start, ceiling)
        if current >= ceiling
          raise ExhaustedError, "no unique code after #{current - start} length bumps (length #{current}) for #{key}"
        end

        longer = current + 1
        learn(key, longer)
        ActiveSupport::Notifications.instrument(EVENT, key: key, table: table, column: column, from: current, to: longer)
        longer
      end

      def taken_among(scope, column, candidates)
        candidates.each_slice(EXISTS_CHUNK).flat_map { |chunk| scope.where(column => chunk).pluck(column) }.to_set
      end

      def compose(prefix, bare) = prefix ? "#{prefix}#{SEPARATOR}#{bare}" : bare

      # Atomic per key: a smaller length never overwrites a larger one.
      def learn(key, length) = LEARNED.compute(key) { |learned| [learned.to_i, length].max }
    end
  end
end
