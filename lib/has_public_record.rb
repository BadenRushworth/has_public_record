# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/object/blank"
require "zeitwerk"
require_relative "has_public_record/version"

loader = Zeitwerk::Loader.for_gem
loader.ignore("#{__dir__}/generators") # Rails generators do not follow constant naming
loader.ignore("#{__dir__}/tasks")      # rake files
loader.ignore("#{__dir__}/has_public_record/version.rb") # required above
loader.ignore("#{__dir__}/has_public_record/railtie.rb") # needs Rails, so it is required below, only under Rails
loader.setup

# Short, prefixed public ids: has_public_record prefix: "usr"  ->  usr_K3F9A2
module HasPublicRecord
  class Error < StandardError; end
  class InvalidPrefixError < Error; end
  class DuplicatePrefixError < Error; end
  class ExhaustedError < Error; end

  SEPARATOR = "_"
  PREFIX_FORMAT = /\A[a-z][a-z0-9]{0,9}\z/
  REF_FORMAT = /\A([a-z][a-z0-9]{0,9})#{SEPARATOR}(\S+)\z/
  Parsed = Data.define(:prefix, :bare)

  @config = Configuration.new
  @registry = Registry.new
  @models_loaded = false

  class << self
    attr_reader :config, :registry

    def configure
      yield(config)
      config
    end

    # "usr_K3F9A2" -> Parsed(prefix: "usr", bare: "K3F9A2"); nil when it is not shaped like a ref.
    def parse(ref)
      match = REF_FORMAT.match(ref.to_s.strip)
      match && Parsed.new(prefix: match[1], bare: match[2])
    end

    def valid?(ref) = !parse(ref).nil?

    # { "usr" => "User", ... } for every model declared so far.
    def prefixes = registry.to_h

    # The prefix a model (class, or class name) declared, or nil.
    def prefix_for(model) = registry.prefix_for(model.is_a?(Module) ? model.name : model)

    # The model class a ref belongs to, or nil (bad shape, unknown prefix, class gone).
    def model_for(ref)
      parsed = parse(ref) or return nil
      name = registry[parsed.prefix]
      if name.nil?
        load_models!
        name = registry[parsed.prefix]
      end
      name&.safe_constantize
    end

    # The record a ref points at, or nil. resolve! raises ActiveRecord::RecordNotFound.
    def resolve(ref)
      model = model_for(ref) or return nil
      model.find_by_public_id(ref)
    end

    def resolve!(ref)
      resolve(ref) || raise(ActiveRecord::RecordNotFound, "Couldn't find a record for public id #{ref.inspect}")
    end

    def generate(...) = Generator.generate(...)

    # For specs: forget every declaration, learned length and setting.
    def reset!
      registry.clear!
      Generator.reset_learned!
      config.reset!
      @models_loaded = false
    end

    private

    # Models register when their class loads. With lazy autoloading (development, tests) a ref for a model nobody
    # touched yet would not resolve, so on the first unknown prefix everything is loaded once.
    def load_models!
      return if @models_loaded

      @models_loaded = true
      Zeitwerk::Loader.eager_load_all
    end
  end
end

ActiveSupport.on_load(:active_record) { extend HasPublicRecord::Macro }
require_relative "has_public_record/railtie" if defined?(Rails::Railtie)
