# frozen_string_literal: true

require_relative "lib/has_public_record/version"

Gem::Specification.new do |spec|
  spec.name        = "has_public_record"
  spec.version     = HasPublicRecord::VERSION
  spec.authors     = ["Baden"]
  spec.email       = ["baden.rushworth@gmail.com"]
  spec.summary     = "Short, prefixed, URL-safe public ids for ActiveRecord models (usr_K3F9A2)."
  spec.description = "has_public_record gives a model a random prefixed public id that grows in length as the table fills."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "README.md", "LICENSE.txt"]

  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
  spec.add_dependency "railties", ">= 7.1"
  spec.add_dependency "zeitwerk", ">= 2.6"
end
