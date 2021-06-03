module Alba
  # Base class for `One` and `Many`
  # Child class should implement `to_hash` method
  class Association
    attr_reader :object, :name

    # @param name [Symbol] name of the method to fetch association
    # @param condition [Proc] a proc filtering data
    # @param resource [Class<Alba::Resource>] a resource class for the association
    # @param block [Block] used to define resource when resource arg is absent
    def initialize(name:, condition: nil, resource: nil, nesting: nil, &block)
      @name = name
      @condition = condition
      @block = block
      @resource = resource
      return if @resource

      assign_resource(nesting)
    end

    private

    def constantize(resource)
      case resource # rubocop:disable Style/MissingElse
      when Class
        resource
      when Symbol, String
        Object.const_get(resource)
      end
    end

    def assign_resource(nesting)
      @resource = if @block
                    Alba.resource_class(&@block)
                  elsif Alba.inferring
                    Alba.infer_resource_class(@name, nesting: nesting)
                  else
                    raise ArgumentError, 'When Alba.inferring is false, either resource or block is required'
                  end
    end
  end
end
