# frozen_string_literal: true

require "test_helper"

class Kml::Infra::CloudflareTest < Minitest::Test
  def setup
    @cloudflare = Kml::Infra::Cloudflare.new(
      api_token: "test-token",
      account_id: "test-account",
      zone_id: "test-zone",
      domain: "example.com"
    )
  end

  def test_initialize_with_api_token_and_zone_id
    cf = Kml::Infra::Cloudflare.new(
      api_token: "my-token",
      account_id: "my-account",
      zone_id: "my-zone",
      domain: "test.com"
    )

    assert_equal "test.com", cf.domain
  end

  def test_domain_accessor
    assert_equal "example.com", @cloudflare.domain
  end

  def test_worker_script_is_defined
    assert_operator Kml::Infra::Cloudflare::WORKER_SCRIPT.length, :>, 100
    assert_includes Kml::Infra::Cloudflare::WORKER_SCRIPT, "export default"
  end

  # Integration tests would mock the Faraday connections
  # For now, we just test the interface exists

  def test_responds_to_ensure_tunnel_dns
    assert_respond_to @cloudflare, :ensure_tunnel_dns
  end

  def test_responds_to_ensure_worker_dns
    assert_respond_to @cloudflare, :ensure_worker_dns
  end

  def test_responds_to_deploy_worker
    assert_respond_to @cloudflare, :deploy_worker
  end

  def test_responds_to_delete_worker
    assert_respond_to @cloudflare, :delete_worker
  end

  # Tunnel management tests

  def test_responds_to_create_tunnel
    assert_respond_to @cloudflare, :create_tunnel
  end

  def test_responds_to_find_tunnel_by_name
    assert_respond_to @cloudflare, :find_tunnel_by_name
  end

  def test_responds_to_delete_tunnel
    assert_respond_to @cloudflare, :delete_tunnel
  end

  def test_worker_script_passes_through_to_tunnel
    # Worker should pass through to tunnel origin, not proxy to Daytona
    assert_includes Kml::Infra::Cloudflare::WORKER_SCRIPT, "return fetch(request)"
    refute_includes Kml::Infra::Cloudflare::WORKER_SCRIPT, "DAYTONA_PREVIEW_URL"
  end

  def test_worker_script_handles_websocket_upgrades
    # WebSocket upgrades should not be redirected (for ActionCable)
    assert_includes Kml::Infra::Cloudflare::WORKER_SCRIPT, "isWebSocket"
    assert_includes Kml::Infra::Cloudflare::WORKER_SCRIPT, 'request.headers.get("Upgrade")'
  end
end
