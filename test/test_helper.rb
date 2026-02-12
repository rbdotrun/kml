# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "kml"
require "minitest/autorun"

# Simple stub class for testing
class TestStub
  def initialize(methods = {})
    @methods = methods
    @calls = Hash.new { |h, k| h[k] = [] }
  end

  def method_missing(name, *args, **kwargs, &block)
    @calls[name] << { args:, kwargs:, block: }
    if @methods.key?(name)
      val = @methods[name]
      val.is_a?(Proc) ? val.call(*args, **kwargs, &block) : val
    end
  end

  def respond_to_missing?(name, include_private = false)
    @methods.key?(name) || super
  end

  def calls(name)
    @calls[name]
  end
end
