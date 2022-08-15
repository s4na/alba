require_relative '../test_helper'

class WithInferenceTest < Minitest::Test
  class User
    attr_reader :id
    attr_accessor :articles

    def initialize(id)
      @id = id
      @articles = []
    end
  end

  class Article
    attr_accessor :id, :title

    def initialize(id, title)
      @id = id
      @title = title
    end
  end

  class BankAccount
    attr_accessor :account_number

    def initialize(account_number)
      @account_number = account_number
    end
  end

  class ArticleResource
    include Alba::Resource

    attributes :title
  end

  class UserResource
    include Alba::Resource

    root_key!

    attributes :id

    many :articles, resource: ArticleResource
  end

  class BankAccountResource
    include Alba::Resource

    root_key!

    attributes :account_number
  end

  class UserInferringResource
    Alba.enable_inference!(with: :active_support) # Need this here instead of initializer
    include Alba::Resource

    attributes :id

    many :articles
  end

  def setup
    Alba.enable_inference!(with: :active_support)
    @user = User.new(1)
    @user.articles << Article.new(1, 'The title')
    @bank_account = BankAccount.new(123_456_789)
  end

  def teardown
    Alba.disable_inference!
  end

  def test_it_infers_resource_name
    assert_equal(
      '{"id":1,"articles":[{"title":"The title"}]}',
      UserInferringResource.new(@user).serialize
    )
  end

  def test_it_infers_key_with_key_bang
    assert_equal(
      '{"user":{"id":1,"articles":[{"title":"The title"}]}}',
      UserResource.new(@user).serialize
    )
  end

  def test_it_infers_key_with_key_bang_when_object_name_has_multiple_words
    assert_equal(
      '{"bank_account":{"account_number":123456789}}',
      BankAccountResource.new(@bank_account).serialize
    )
  end

  def test_it_infers_key_with_key_bang_when_object_is_collection_and_object_name_has_multiple_words
    bank_accounts = [@bank_account]
    assert_equal(
      '{"bank_accounts":[{"account_number":123456789}]}',
      BankAccountResource.new(bank_accounts).serialize
    )
  end

  def test_it_infers_key_with_key_bang_when_object_is_collection
    users = [User.new(1), User.new(2)]
    assert_equal(
      '{"users":[{"id":1,"articles":[]},{"id":2,"articles":[]}]}',
      UserResource.new(users).serialize
    )
  end

  def test_it_prioritize_serialize_arg_with_key_bang
    assert_equal(
      '{"foo":{"id":1,"articles":[{"title":"The title"}]}}',
      UserResource.new(@user).serialize(root_key: :foo)
    )
  end

  def test_inline_definition_works_with_inference
    assert_equal(
      '{"id":1,"articles":[{"title":"The title"}]}',
      Alba.serialize(@user) do
        attributes :id
        many :articles do
          attributes :title
        end
      end
    )
  end
end

# Test inference with `dry-inflector`
class InferenceTestWithDry < WithInferenceTest
  def setup
    super
    Alba.enable_inference!(with: :dry)
  end
end

# Test inference with custom inflector
class InferenceTestWithCustomInflector < WithInferenceTest
  def setup
    super
    inflector = Object.new.tap do |i|
      def i.camelize; end
      def i.camelize_lower; end
      def i.dasherize; end
      def i.classify; end

      def i.demodulize(str)
        str.split('::').last
      end

      def i.underscore(str)
        str.gsub(/::/, '/').gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').tr('-', '_').downcase
      end

      def i.pluralize(str)
        "#{str}s"
      end
    end
    Alba.enable_inference!(with: inflector)
  end
end

class InferenceTestWithInvalidInflector < Minitest::Test
  def test_it_raises_an_error_with_invalid_custom_inflector
    assert_raises(Alba::Error) do
      Alba.enable_inference!(with: Object.new)
    end
  end
end
