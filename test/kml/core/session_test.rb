# frozen_string_literal: true

require "test_helper"

class Kml::Core::SessionTest < Minitest::Test
  def setup
    @ai = TestStub.new
    @daytona = TestStub.new(
      get_sandbox: { "state" => "started" }
    )
    @cloudflare = TestStub.new(
      domain: "example.com"
    )
  end

  def build_session(**overrides)
    defaults = {
      slug: "test-session",
      ai: @ai,
      daytona: @daytona,
      cloudflare: @cloudflare,
      git_repo: "https://github.com/user/repo.git",
      service_name: "my-app"
    }
    Kml::Core::Session.new(**defaults.merge(overrides))
  end

  def test_initialize_accepts_all_params
    session = build_session

    assert_equal "test-session", session.slug
  end

  def test_public_url_returns_slug_domain
    session = build_session

    assert_equal "https://test-session.example.com", session.public_url
  end

  def test_public_url_returns_nil_without_cloudflare
    session = build_session(cloudflare: nil)

    assert_nil session.public_url
  end

  def test_code_path
    session = build_session

    assert_equal "/home/daytona/app", session.code_path
  end

  def test_running_returns_false_without_sandbox_id
    session = build_session

    refute_predicate session, :running?
  end

  def test_running_returns_true_when_sandbox_started
    daytona = TestStub.new(
      get_sandbox: { "state" => "started" }
    )
    session = build_session(daytona:, sandbox_id: "sandbox-123")

    assert_predicate session, :running?
  end

  def test_running_returns_false_when_sandbox_stopped
    daytona = TestStub.new(
      get_sandbox: { "state" => "stopped" }
    )
    session = build_session(daytona:, sandbox_id: "sandbox-123")

    refute_predicate session, :running?
  end

  def test_to_h_returns_slug
    session = build_session

    assert_equal "test-session", session.to_h[:slug]
  end

  def test_to_h_returns_sandbox_id
    session = build_session(sandbox_id: "sb-123")

    assert_equal "sb-123", session.to_h[:sandbox_id]
  end

  def test_to_h_returns_access_token
    session = build_session(access_token: "token-abc")

    assert_equal "token-abc", session.to_h[:access_token]
  end

  def test_access_token_generated_if_not_provided
    session = build_session

    assert_match(/\A[a-f0-9]{64}\z/, session.access_token)
  end

  def test_uses_runtime_defaults_when_install_empty
    session = build_session(install: [])

    assert_instance_of Kml::Core::Session, session
  end

  def test_uses_provided_install_commands
    session = build_session(install: [ "custom install" ])

    assert_instance_of Kml::Core::Session, session
  end

  # Tunnel tests

  def test_tunnel_id_accessor
    session = build_session(tunnel_id: "tunnel-123")

    assert_equal "tunnel-123", session.tunnel_id
  end

  def test_tunnel_token_accessor
    session = build_session(tunnel_token: "token-xyz")

    assert_equal "token-xyz", session.tunnel_token
  end

  def test_to_h_returns_tunnel_id
    session = build_session(tunnel_id: "tunnel-456")

    assert_equal "tunnel-456", session.to_h[:tunnel_id]
  end

  def test_to_h_returns_tunnel_token
    session = build_session(tunnel_token: "token-abc")

    assert_equal "token-abc", session.to_h[:tunnel_token]
  end

  def test_tunnel_id_nil_by_default
    session = build_session

    assert_nil session.tunnel_id
  end

  def test_tunnel_token_nil_by_default
    session = build_session

    assert_nil session.tunnel_token
  end

  def test_install_error_class_exists
    assert_kind_of Class, Kml::Core::InstallError
    assert_operator Kml::Core::InstallError, :<, StandardError
  end
end
