# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/number_helper"
require "digest"
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
  REF_FORMAT = /\A([a-z][a-z0-9]{0,9})#{SEPARATOR}(\S+)\z/i # any letter case: people type ids
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
      match = REF_FORMAT.match(ref.to_s.strip) or return nil
      Parsed.new(prefix: match[1].downcase, bare: fold_case(match[2]))
    end

    def valid?(ref) = !parse(ref).nil?

    # Ids are stored in one case. When the alphabet has only upper-case (or only lower-case) letters, anything typed
    # is folded to it; an alphabet with both cases is left exactly as typed.
    def fold_case(text)
      alphabet = config.alphabet
      if alphabet == alphabet.upcase then text.upcase
      elsif alphabet == alphabet.downcase then text.downcase
      else text
      end
    end

    # The stored form ("usr_K3F9A2") of a ref that belongs to prefix; the bare code is accepted. nil for a ref of
    # another prefix or a blank one. With no prefix, just the folded text.
    def canonicalize(ref, prefix)
      text = ref.to_s.strip
      return nil if text.empty?
      return fold_case(text) unless prefix

      head, separator, tail = text.partition(SEPARATOR)
      if separator.empty?
        "#{prefix}#{SEPARATOR}#{fold_case(head)}"
      elsif head.downcase == prefix && !tail.empty?
        "#{prefix}#{SEPARATOR}#{fold_case(tail)}"
      end
    end

    # Whether ref is an id this prefix could have issued: the prefix, then only characters of the current alphabet.
    # For vetting ids that are GIVEN. Lookups use canonicalize, which does not check the alphabet, so ids made under an
    # older alphabet stay findable.
    def well_formed?(ref, prefix)
      head, separator, tail = ref.to_s.partition(SEPARATOR)
      return false if separator.empty? || head != prefix.to_s || tail.empty?

      alphabet = config.alphabet
      tail.each_char.all? { |char| alphabet.include?(char) }
    end

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

    # Mixed refs (an audit log, polymorphic references) in one query per model, not one per ref.
    # Returns { ref => record } for the refs that resolved, keyed by the ref as given. Bare codes cannot be
    # resolved without a model, so they are skipped.
    def resolve_many(*refs)
      found = {}
      refs.flatten.compact.uniq.group_by { |ref| model_for(ref) }.each do |model, list|
        next unless model

        by_id = model.with_public_id(list).index_by { |record| record[model.public_id_column] }
        list.each do |ref|
          record = by_id[model.normalize_public_id(ref)]
          found[ref] = record if record
        end
      end
      found
    end

    # Makes an id without a model; see Generator and Identifier.
    #   HasPublicRecord.generate("inv", length: 8) { |id| !Invoice.exists?(number: id) }
    def generate(prefix = nil, **options, &block) = Generator.generate(**{ prefix: prefix }.merge(options), &block)

    def identifier(prefix = nil, **options, &free) = Identifier.new(prefix, **options, &free)

    # A stable id for a label, for fixtures and seeds: the same label always gives the same id.
    def fixture_id(prefix, label, length: config.default_length)
      number = Digest::SHA512.hexdigest("#{prefix}:#{label}").to_i(16)
      chars = config.alphabet.chars
      bare = Array.new(length) do
        number, digit = number.divmod(chars.size)
        chars[digit]
      end.join
      prefix ? "#{prefix}#{SEPARATOR}#{bare}" : bare
    end

    # Forgets which class declared which prefix. Rails calls this when it unloads code in development, so a renamed
    # class or prefix does not raise DuplicatePrefixError; the reloaded classes declare themselves again.
    def reset_registry!
      registry.clear!
      @models_loaded = false
    end

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
