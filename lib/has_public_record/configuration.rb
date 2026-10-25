# frozen_string_literal: true

module HasPublicRecord
  # HasPublicRecord.configure { |c| c.default_length = 8 }
  class Configuration
    DEFAULT_ALPHABET = (("0".."9").to_a + ("A".."Z").to_a).join.freeze
    # No 0/O or 1/I/L: easier to read aloud and to type from a screenshot.
    UNAMBIGUOUS = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
    PRESETS = { default: DEFAULT_ALPHABET, unambiguous: UNAMBIGUOUS }.freeze

    attr_reader :default_length, :attempts_per_length, :max_length_bumps, :alphabet, :lengths

    def initialize = reset!

    def reset!
      @default_length = 6        # starting length of the random part (the prefix is extra)
      @attempts_per_length = 10  # random tries before the length grows by one
      @max_length_bumps = 4      # growth steps before ExhaustedError
      @alphabet = DEFAULT_ALPHABET
      @lengths = {}.freeze       # per-table starting length: { "users" => 8 }
      self
    end

    def default_length=(value)
      @default_length = integer!(value, :default_length, min: 1)
    end

    def attempts_per_length=(value)
      @attempts_per_length = integer!(value, :attempts_per_length, min: 1)
    end

    def max_length_bumps=(value)
      @max_length_bumps = integer!(value, :max_length_bumps, min: 0)
    end

    def alphabet=(value)
      if value.is_a?(Symbol)
        value = PRESETS.fetch(value) { raise ArgumentError, "unknown alphabet preset #{value.inspect} (expected #{PRESETS.keys.join(', ')})" }
      end
      chars = value.to_s.each_char.uniq
      raise ArgumentError, "alphabet needs at least 2 distinct characters" if chars.size < 2
      if chars.any? { |char| char == SEPARATOR || char.match?(/\s/) }
        raise ArgumentError, "alphabet cannot contain #{SEPARATOR.inspect} or whitespace"
      end

      @alphabet = chars.join.freeze
    end

    def lengths=(value)
      @lengths = value.to_h.to_h { |table, length| [table.to_s, integer!(length, "lengths[#{table}]", min: 1)] }.freeze
    end

    private

    def integer!(value, name, min:)
      number = Integer(value)
      raise ArgumentError, "#{name} must be at least #{min}" if number < min

      number
    rescue TypeError, ArgumentError => e
      raise ArgumentError, e.message.start_with?(name.to_s) ? e.message : "#{name}: #{e.message}"
    end
  end
end
