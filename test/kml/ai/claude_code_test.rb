# frozen_string_literal: true

require "test_helper"

class Kml::Ai::ClaudeCodeTest < Minitest::Test
  def setup
    @ai = Kml::Ai::ClaudeCode.new(auth_token: "test-token")
  end

  def test_initialize_with_auth_token
    ai = Kml::Ai::ClaudeCode.new(auth_token: "my-token")

    assert_includes ai.env_vars["ANTHROPIC_AUTH_TOKEN"], "my-token"
  end

  def test_initialize_with_base_url
    ai = Kml::Ai::ClaudeCode.new(auth_token: "token", base_url: "https://custom.api")

    assert_equal "https://custom.api", ai.env_vars["ANTHROPIC_BASE_URL"]
  end

  def test_env_vars_includes_auth_token
    assert_equal "test-token", @ai.env_vars["ANTHROPIC_AUTH_TOKEN"]
  end

  def test_env_vars_includes_base_url_when_set
    ai = Kml::Ai::ClaudeCode.new(auth_token: "token", base_url: "https://api.example.com")

    assert_equal "https://api.example.com", ai.env_vars["ANTHROPIC_BASE_URL"]
  end

  def test_env_vars_excludes_base_url_when_nil
    refute @ai.env_vars.key?("ANTHROPIC_BASE_URL")
  end

  def test_build_command_with_new_session
    cmd = @ai.build_command("--session-id abc123", "test prompt")

    assert_includes cmd, "--session-id abc123"
    assert_includes cmd, "claude"
    assert_includes cmd, "--output-format=stream-json"
  end

  def test_build_command_with_resume
    cmd = @ai.build_command("--resume abc123", "test prompt")

    assert_includes cmd, "--resume abc123"
  end

  def test_build_command_escapes_prompt
    cmd = @ai.build_command("--session-id x", "prompt with 'quotes' and spaces")

    assert_includes cmd, "prompt"
    # Should be shell-escaped (Shellwords.escape uses backslash escaping)
    assert_includes cmd, "\\"
  end

  def test_run_yields_json_lines
    outputs = []
    executor = lambda do |cmd, &block|
      # Simulate PTY output with JSON - needs {"type": to trigger output_started
      block.call('{"type":"message","content":"hello"}' + "\n")
    end

    @ai.run(
      prompt: "test",
      session_id: "123",
      cwd: "/tmp",
      executor:
    ) do |line|
      outputs << line
    end

    assert_equal 1, outputs.size
    assert_includes outputs.first, '"type":"message"'
  end
end
