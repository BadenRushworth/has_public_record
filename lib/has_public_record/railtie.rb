# frozen_string_literal: true

require "rails/railtie"

module HasPublicRecord
  # Loads the rake tasks, and forgets declared prefixes when Rails unloads code in development. Generators need no
  # hook: Rails finds lib/generators of every gem on the load path.
  #
  # before_class_unload, not to_prepare: to_prepare also runs at boot, and a model loaded before it would be wiped
  # from the registry without ever being reloaded to declare itself again.
  class Railtie < ::Rails::Railtie
    rake_tasks { load File.expand_path("../tasks/has_public_record.rake", __dir__) }

    initializer "has_public_record.reloader" do
      ActiveSupport::Reloader.before_class_unload { HasPublicRecord.reset_registry! }
    end
  end
end
