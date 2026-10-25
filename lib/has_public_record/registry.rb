# frozen_string_literal: true

module HasPublicRecord
  # prefix -> class NAME ("usr" => "User"). Names, not classes: a class object goes stale when Rails reloads code,
  # a name is constantized fresh on lookup. Declaring the same prefix again from the same class (a reload) is a
  # no-op; from a different class it raises, which is what makes prefixes unique.
  class Registry
    def initialize
      @map = {}.freeze
      @mutex = Mutex.new
    end

    def register(prefix, class_name)
      prefix = prefix.to_s
      unless PREFIX_FORMAT.match?(prefix)
        raise InvalidPrefixError, "invalid prefix #{prefix.inspect} (expected #{PREFIX_FORMAT.inspect}: lower-case letters and digits, starting with a letter, 10 at most)"
      end
      raise InvalidPrefixError, "a model needs a class name to declare a prefix (anonymous class)" if class_name.blank?

      @mutex.synchronize do
        existing = @map[prefix]
        if existing && existing != class_name
          raise DuplicatePrefixError, "prefix #{prefix.inspect} is already used by #{existing}, so #{class_name} cannot use it"
        end

        @map = @map.merge(prefix => class_name).freeze
      end
      prefix
    end

    def [](prefix) = @map[prefix.to_s]
    def prefix_for(class_name) = @map.key(class_name.to_s)
    def to_h = @map
    def clear! = @mutex.synchronize { @map = {}.freeze }
  end
end
