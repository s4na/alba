# frozen_string_literal: true

require 'json'
require_relative 'alba/version'
require_relative 'alba/errors'
require_relative 'alba/resource'
require_relative 'alba/deprecation'

require_relative 'alba/railtie' if defined?(Rails::Railtie)

# Core module
module Alba
  class << self
    attr_reader :backend, :encoder

    # Getter for inflector, a module responsible for inflecting strings
    attr_reader :inflector

    # Set the backend, which actually serializes object into JSON
    #
    # @param backend [#to_sym, nil] the name of the backend
    #   Possible values are `oj`, `active_support`, `default`, `json` and nil
    # @return [Proc] the proc to encode object into JSON
    # @raise [Alba::UnsupportedBackend] if backend is not supported
    def backend=(backend)
      @backend = backend&.to_sym
      set_encoder_from_backend
    end

    # Set encoder, a Proc object that accepts an object and generates JSON from it
    # Set backend as `:custom` which indicates no preset encoder is used
    #
    # @param encoder [Proc]
    # @raise [ArgumentError] if given encoder is not a Proc or its arity is not one
    def encoder=(encoder)
      raise ArgumentError, 'Encoder must be a Proc accepting one argument' unless encoder.is_a?(Proc) && encoder.arity == 1

      @encoder = encoder
      @backend = :custom
    end

    # Serialize the object with inline definitions
    #
    # @param object [Object] the object to be serialized
    # @param root_key [Symbol, nil, true]
    # @param block [Block] resource block
    # @return [String] serialized JSON string
    # @raise [ArgumentError] if block is absent or `with` argument's type is wrong
    def serialize(object = nil, root_key: nil, &block)
      resource = resource_with(object, &block)
      resource.serialize(root_key: root_key)
    end

    # Hashify the object with inline definitions
    #
    # @param object [Object] the object to be serialized
    # @param root_key [Symbol, nil, true]
    # @param block [Block] resource block
    # @return [String] serialized JSON string
    # @raise [ArgumentError] if block is absent or `with` argument's type is wrong
    def hashify(object = nil, root_key: nil, &block)
      resource = resource_with(object, &block)
      resource.as_json(root_key: root_key)
    end

    # Enable inference for key and resource name
    #
    # @param with [Symbol, Class, Module] inflector
    #   When it's a Symbol, it sets inflector with given name
    #   When it's a Class or a Module, it sets given object to inflector
    # @deprecated Use {.inflector=} instead
    def enable_inference!(with:)
      Alba::Deprecation.warn('Alba.enable_inference! is deprecated. Use `Alba.inflector=` instead.')
      @inflector = inflector_from(with)
      @inferring = true
    end

    # Disable inference for key and resource name
    #
    # @deprecated Use {.inflector=} instead
    def disable_inference!
      Alba::Deprecation.warn('Alba.disable_inference! is deprecated. Use `Alba.inflector = nil` instead.')
      @inferring = false
      @inflector = nil
    end

    # @deprecated Use {.inflector} instead
    # @return [Boolean] whether inference is enabled or not
    def inferring
      Alba::Deprecation.warn('Alba.inferring is deprecated. Use `Alba.inflector` instead.')
      @inferring
    end

    # Set an inflector
    #
    # @param inflector [Symbol, Class, Module] inflector
    #   When it's a Symbol, it accepts `:default`, `:active_support` or `:dry`
    #   When it's a Class or a Module, it should have some methods, see {Alba::DefaultInflector}
    def inflector=(inflector)
      @inflector = inflector_from(inflector)
    end

    # @param block [Block] resource body
    # @return [Class<Alba::Resource>] resource class
    def resource_class(&block)
      klass = Class.new
      klass.include(Alba::Resource)
      klass.class_eval(&block) if block
      klass
    end

    # @param name [String] a String Alba infers resource name with
    # @param nesting [String, nil] namespace Alba tries to find resource class in
    # @return [Class<Alba::Resource>] resource class
    def infer_resource_class(name, nesting: nil)
      raise Alba::Error, 'Inference is disabled so Alba cannot infer resource name. Set inflector before use.' unless Alba.inflector

      const_parent = nesting.nil? ? Object : Object.const_get(nesting)
      begin
        const_parent.const_get("#{inflector.classify(name)}Resource")
      rescue NameError # Retry for serializer
        const_parent.const_get("#{inflector.classify(name)}Serializer")
      end
    end

    # Configure Alba to symbolize keys
    def symbolize_keys!
      @symbolize_keys = true
    end

    # Configure Alba to stringify (not symbolize) keys
    def stringify_keys!
      @symbolize_keys = false
    end

    # Regularize key to be either Symbol or String depending on @symbolize_keys
    # Returns nil if key is nil
    #
    # @param key [String, Symbol, nil]
    # @return [Symbol, String, nil]
    def regularize_key(key)
      return if key.nil?

      @symbolize_keys ? key.to_sym : key.to_s
    end

    # Register types, used for both builtin and custom types
    #
    # @see Alba::Type
    # @return [void]
    def register_type(name, check: false, converter: nil, auto_convert: false)
      @types[name] = Type.new(name, check: check, converter: converter, auto_convert: auto_convert)
    end

    # Find type by name
    #
    # @return [Alba::Type]
    def find_type(name)
      @types.fetch(name) do
        raise(Alba::UnsupportedType, "Unknown type: #{name}")
      end
    end

    # Reset config variables
    # Useful for test cleanup
    def reset!
      @encoder = default_encoder
      @symbolize_keys = false
      @_on_error = :raise
      @_on_nil = nil
      @types = {}
      register_default_types
    end

    # This method could be part of public API, but for now it's private
    def resource_with(object, &block)
      klass = block ? resource_class(&block) : infer_resource_class(object.class.name)

      klass.new(object)
    end

    private

    def inflector_from(name_or_module)
      case name_or_module
      when nil then nil
      when :default, :active_support
        require_relative 'alba/default_inflector'
        Alba::DefaultInflector
      when :dry
        require 'dry/inflector'
        Dry::Inflector.new
      else validate_inflector(name_or_module)
      end
    end

    def set_encoder_from_backend
      @encoder = case @backend
                 when :oj, :oj_strict then try_oj(mode: :strict)
                 when :oj_rails then try_oj(mode: :rails)
                 when :oj_default then try_oj(mode: :default)
                 when :active_support then try_active_support
                 when nil, :default, :json then default_encoder
                 else
                   raise Alba::UnsupportedBackend, "Unsupported backend, #{backend}"
                 end
    end

    def try_oj(mode:)
      require 'oj'
      case mode
      when :default
        ->(hash) { Oj.dump(hash) }
      else
        ->(hash) { Oj.dump(hash, mode: mode) }
      end
    rescue LoadError
      Kernel.warn '`Oj` is not installed, falling back to default JSON encoder.'
      default_encoder
    end

    def try_active_support
      require 'active_support/json'
      ->(hash) { ActiveSupport::JSON.encode(hash) }
    rescue LoadError
      Kernel.warn '`ActiveSupport` is not installed, falling back to default JSON encoder.'
      default_encoder
    end

    def default_encoder
      lambda do |hash|
        JSON.generate(hash)
      end
    end

    def validate_inflector(inflector)
      unless %i[camelize camelize_lower dasherize classify].all? { |m| inflector.respond_to?(m) }
        raise Alba::Error, "Given inflector, #{inflector.inspect} is not valid. It must implement `camelize`, `camelize_lower`, `dasherize` and `classify`."
      end

      inflector
    end

    def register_default_types # rubocop:disable Mertics/AbcSize
      [String, :String].each do |t|
        register_type(t, check: ->(obj) { obj.is_a?(String) }, converter: lambda(&:to_s))
      end
      [Integer, :Integer].each do |t|
        register_type(t, check: ->(obj) { obj.is_a?(Integer) }, converter: ->(obj) { Integer(obj) })
      end
      register_type(:Boolean, check: ->(obj) { [true, false].include?(obj) }, converter: ->(obj) { !!obj })
      [String, Integer].each do |t|
        register_type(:"ArrayOf#{t}", check: ->(d) { d.is_a?(Array) && d.all? { _1.is_a?(t) } })
      end
    end
  end

  reset!
end
