# frozen_string_literal: true

require "test_helper"

class Kml::Ai::BaseTest < Minitest::Test
  def setup
    @base = Kml::Ai::Base.new
  end

  def test_run_raises_not_implemented
    assert_raises(NotImplementedError) do
      @base.run(prompt: "test", session_id: "123", cwd: "/tmp", executor: -> { })
    end
  end

  def test_env_vars_returns_empty_hash
    assert_empty(@base.env_vars)
  end

  def test_build_command_raises_not_implemented
    assert_raises(NotImplementedError) do
      @base.build_command("--session-id 123", "test prompt")
    end
  end
end
