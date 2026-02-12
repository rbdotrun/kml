# frozen_string_literal: true

require "test_helper"

class Kml::Runtime::BaseTest < Minitest::Test
  def setup
    @base = Kml::Runtime::Base.new
  end

  def test_dockerfile_raises_not_implemented
    assert_raises(NotImplementedError) do
      @base.dockerfile
    end
  end

  def test_default_install_returns_empty_array
    assert_empty @base.default_install
  end

  def test_default_processes_returns_empty_hash
    assert_empty(@base.default_processes)
  end

  def test_default_port_returns_3000
    assert_equal 3000, @base.default_port
  end
end
