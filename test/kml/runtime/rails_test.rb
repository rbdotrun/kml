# frozen_string_literal: true

require "test_helper"

class Kml::Runtime::RailsTest < Minitest::Test
  def setup
    @rails = Kml::Runtime::Rails.new
  end

  def test_dockerfile_returns_valid_dockerfile
    assert_kind_of String, @rails.dockerfile
    assert_operator @rails.dockerfile.length, :>, 100
  end

  def test_dockerfile_includes_from_ubuntu
    assert_includes @rails.dockerfile, "FROM ubuntu:24.04"
  end

  def test_dockerfile_includes_mise
    assert_includes @rails.dockerfile, "mise"
  end

  def test_dockerfile_includes_ruby
    assert_includes @rails.dockerfile, "ruby@3.3"
  end

  def test_dockerfile_includes_node
    assert_includes @rails.dockerfile, "node@22"
  end

  def test_dockerfile_includes_postgres
    assert_includes @rails.dockerfile, "postgresql"
  end

  def test_dockerfile_includes_cloudflared
    assert_includes @rails.dockerfile, "cloudflared"
  end

  def test_dockerfile_includes_claude_code
    assert_includes @rails.dockerfile, "@anthropic-ai/claude-code"
  end

  def test_default_install_includes_bundle_install
    assert_includes @rails.default_install, "bundle install"
  end

  def test_default_install_includes_db_prepare
    assert_includes @rails.default_install, "bin/rails db:prepare"
  end

  def test_default_processes_includes_web
    assert @rails.default_processes.key?("web")
    assert_includes @rails.default_processes["web"], "rails server"
  end

  def test_default_port_returns_3000
    assert_equal 3000, @rails.default_port
  end
end
