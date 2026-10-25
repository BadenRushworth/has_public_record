# frozen_string_literal: true

require "rails/railtie"

module HasPublicRecord
  # Loads the rake tasks. Generators need no hook: Rails finds lib/generators of every gem on the load path.
  class Railtie < ::Rails::Railtie
    rake_tasks { load File.expand_path("../tasks/has_public_record.rake", __dir__) }
  end
end
