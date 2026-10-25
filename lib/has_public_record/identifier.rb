# frozen_string_literal: true

module HasPublicRecord
  # Ids without a model: order numbers, API keys, Redis keys.
  #
  #   invoices = HasPublicRecord.identifier("inv", length: 8) { |id| !Invoice.exists?(number: id) }
  #   invoices.generate            # => "inv_7K2QX9AB"
  #   invoices.valid?("inv_7k2qx9ab")   # => true
  #   invoices.bare("inv_7K2QX9AB")     # => "7K2QX9AB"
  #
  # The prefix is optional (then key: names the generator), but is not registered for HasPublicRecord.resolve:
  # only models are. A prefix a model already declared is refused (best effort: models not loaded yet are unknown).
  class Identifier
    attr_reader :prefix, :key, :length, :max_bumps

    def initialize(prefix = nil, length: nil, max_bumps: nil, key: nil, &free)
      raise ArgumentError, "an identifier needs a block that says whether an id is free" unless free

      @prefix = Generator.check_prefix(prefix)
      if @prefix && (owner = HasPublicRecord.registry[@prefix])
        raise DuplicatePrefixError, "prefix #{@prefix.inspect} is already used by #{owner}"
      end

      @key = (key || @prefix)&.to_s
      raise ArgumentError, "an identifier with no prefix needs key:" if @key.nil?

      @length = length
      @max_bumps = max_bumps
      @free = free
    end

    def generate = Generator.generate(prefix: prefix, length: length, max_bumps: max_bumps, key: key, &@free)

    # The code without the prefix, case folded; nil when the ref belongs elsewhere.
    def bare(ref)
      canonical = HasPublicRecord.canonicalize(ref, prefix)
      canonical && (prefix ? canonical.delete_prefix("#{prefix}#{SEPARATOR}") : canonical)
    end

    # Shaped like one of this identifier's ids: its prefix, then only alphabet characters.
    def valid?(ref)
      code = bare(ref)
      !code.nil? && !code.empty? && code.each_char.all? { |char| HasPublicRecord.config.alphabet.include?(char) }
    end
  end
end
