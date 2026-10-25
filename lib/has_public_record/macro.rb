# frozen_string_literal: true

module HasPublicRecord
  # Extended onto ActiveRecord::Base, so `has_public_record` exists in every model.
  module Macro
    # prefix:    required, unique across the app ("usr")
    # column:    where the id is stored (default :public_id)
    # length:    starting length of the random part for this model (config.lengths[table] beats it)
    # max_bumps: how far the length may grow (default config.max_length_bumps)
    def has_public_record(prefix:, column: :public_id, length: nil, max_bumps: nil)
      include HasPublicRecord::Model
      declare_public_record(prefix: prefix, column: column, length: length, max_bumps: max_bumps)
    end
  end
end
