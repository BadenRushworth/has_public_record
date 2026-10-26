# frozen_string_literal: true

module HasPublicRecord
  # The attribute type of a public id column. Assigning "usr_k3f9a2" or "K3F9A2" stores "usr_K3F9A2", and values used
  # in where / find_by are normalized the same way, so lookups work in any letter case.
  #
  # Reading is deliberately NOT normalized: a row is returned exactly as stored. A legacy bare code stays visible as
  # bare (the report and the prefix tools need to see it) instead of looking fine while the database says otherwise.
  class PublicIdType < ActiveRecord::Type::String
    attr_reader :prefix

    def initialize(prefix:, **options)
      super(**options)
      @prefix = prefix
    end

    def cast(value) = canonical(super)

    def serialize(value) = value.is_a?(::String) ? super(canonical(value)) : super

    def deserialize(value) = value.nil? ? nil : value.to_s

    # Two types with different prefixes are different types (the base class would call them equal).
    def ==(other) = super && prefix == other.prefix
    def eql?(other) = self == other
    def hash = [super, prefix].hash

    private

    # Junk is left as typed: the model's validation reports it, nothing is silently rewritten.
    def canonical(text)
      return text if text.blank?

      HasPublicRecord.canonicalize(text, prefix) || text
    end
  end
end
