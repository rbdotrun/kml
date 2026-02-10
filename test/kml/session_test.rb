# frozen_string_literal: true

require "test_helper"

class SessionTest < Minitest::Test
  def setup
    @mock_sandbox = MockSandbox.new
  end

  def test_tmux_name
    session = Kml::Session.new(slug: "auth-feature", sandbox: @mock_sandbox)
    assert_equal "kml-auth-feature", session.tmux_name
  end

  def test_worktree_path
    session = Kml::Session.new(slug: "auth", sandbox: @mock_sandbox)
    assert_equal "/home/deploy/sessions/auth", session.worktree_path
  end

  def test_container_name
    session = Kml::Session.new(slug: "auth", sandbox: @mock_sandbox)
    assert_equal "kml-auth-app", session.container_name
  end

  def test_postgres_container
    session = Kml::Session.new(slug: "auth", sandbox: @mock_sandbox)
    assert_equal "dummy-rails-sandbox-db", session.postgres_container
  end

  def test_docker_image
    session = Kml::Session.new(slug: "auth", sandbox: @mock_sandbox)
    assert_equal "localhost:5001/dummy-rails:latest-sandbox", session.docker_image
  end

  def test_database_name_with_dashes
    session = Kml::Session.new(slug: "my-feature", sandbox: @mock_sandbox)
    assert_equal "app_session_my_feature", session.database
  end

  def test_build_claude_cmd_interactive
    session = Kml::Session.new(
      slug: "test",
      uuid: "abc-123",
      sandbox: @mock_sandbox
    )
    cmd = session.build_claude_cmd(new_session: true)

    assert_includes cmd, "--session-id abc-123"
    assert_includes cmd, "--verbose"
    assert_includes cmd, "--dangerously-skip-permissions"
    assert_includes cmd, "cd /home/deploy/sessions/test"
    refute_includes cmd, "claude -p"  # interactive mode should not have -p flag
  end

  def test_build_claude_cmd_print_mode
    session = Kml::Session.new(
      slug: "test",
      uuid: "abc-123",
      sandbox: @mock_sandbox
    )
    cmd = session.build_claude_cmd(prompt: "hello world", new_session: true, print_mode: true)

    assert_includes cmd, "-p"
    assert_includes cmd, "hello\\ world"
    assert_includes cmd, "--session-id abc-123"
  end

  def test_build_claude_cmd_json_mode
    session = Kml::Session.new(
      slug: "test",
      uuid: "abc-123",
      sandbox: @mock_sandbox
    )
    cmd = session.build_claude_cmd(prompt: "hello", new_session: true, json_mode: true)

    assert_includes cmd, "-p"
    assert_includes cmd, "--output-format=stream-json"
    assert_includes cmd, "hello"
  end

  def test_build_claude_cmd_resume
    session = Kml::Session.new(
      slug: "test",
      uuid: "abc-123",
      sandbox: @mock_sandbox
    )
    cmd = session.build_claude_cmd(prompt: "continue", new_session: false, print_mode: true)

    assert_includes cmd, "--resume abc-123"
    refute_includes cmd, "--session-id"
  end

  def test_start_requires_prompt_for_print_mode
    session = Kml::Session.new(
      slug: "test",
      uuid: "abc-123",
      port: 3001,
      sandbox: @mock_sandbox
    )

    error = assert_raises(Kml::Error) do
      session.start!(print_mode: true)
    end
    assert_includes error.message, "Prompt required"
  end

  def test_start_requires_prompt_for_detached
    session = Kml::Session.new(
      slug: "test",
      uuid: "abc-123",
      port: 3001,
      sandbox: @mock_sandbox
    )

    error = assert_raises(Kml::Error) do
      session.start!(detached: true)
    end
    assert_includes error.message, "Prompt required"
  end

  def test_start_requires_prompt_for_json_mode
    session = Kml::Session.new(
      slug: "test",
      uuid: "abc-123",
      port: 3001,
      sandbox: @mock_sandbox
    )

    error = assert_raises(Kml::Error) do
      session.start!(json_mode: true)
    end
    assert_includes error.message, "Prompt required"
  end

  class MockSandbox
    def service_name
      "dummy-rails"
    end

    def code_path
      "/opt/dummy-rails"
    end

    def server_ip
      "192.168.1.1"
    end

    def remote_exec(cmd)
      ""
    end

    def anthropic_env_vars
      "ANTHROPIC_API_KEY=test-key"
    end
  end
end
