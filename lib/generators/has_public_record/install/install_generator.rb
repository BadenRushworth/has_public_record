# frozen_string_literal: true

require "rails/generators"

module HasPublicRecord
  module Generators
    # rails g has_public_record:install  ->  config/initializers/has_public_record.rb
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)
      desc "Creates config/initializers/has_public_record.rb with every setting, commented out."

      def create_initializer
        @defaults = HasPublicRecord::Configuration.new
        template "initializer.rb.tt", "config/initializers/has_public_record.rb"
      end

      private

      attr_reader :defaults
    end
  end
end
