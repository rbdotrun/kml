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

  # build_worker_script tests

  def test_build_worker_script_generates_valid_script
    script = @cloudflare.build_worker_script
    assert_operator script.length, :>, 100
    assert_includes script, "export default"
  end

  def test_build_worker_script_passes_through_to_tunnel
    script = @cloudflare.build_worker_script
    # Worker should pass through to tunnel origin, not proxy to Daytona
    assert_includes script, "response"
    refute_includes script, "DAYTONA_PREVIEW_URL"
  end

  def test_build_worker_script_handles_websocket_upgrades
    script = @cloudflare.build_worker_script
    # WebSocket upgrades should not be redirected (for ActionCable)
    assert_includes script, "isWebSocket"
    assert_includes script, 'request.headers.get("Upgrade")'
  end

  def test_build_worker_script_with_no_injection_returns_response
    script = @cloudflare.build_worker_script
    assert_includes script, "return response;"
    refute_includes script, "HTMLRewriter"
  end

  def test_build_worker_script_with_injection_uses_html_rewriter
    injection = "<script>console.log('hello')</script>"
    script = @cloudflare.build_worker_script(injection: injection)
    assert_includes script, "HTMLRewriter"
    assert_includes script, "text/html"
    assert_includes script, "el.append"
  end

  def test_build_worker_script_with_files_generates_imports
    script = @cloudflare.build_worker_script(files: { "console.js" => "content" })
    assert_includes script, "import console from './console.js';"
  end

  def test_build_worker_script_with_multiple_files_generates_multiple_imports
    script = @cloudflare.build_worker_script(files: {
      "console.js" => "content1",
      "other.js" => "content2"
    })
    assert_includes script, "import console from './console.js';"
    assert_includes script, "import other from './other.js';"
  end

  # build_bindings tests

  def test_build_bindings_always_includes_access_token
    bindings = @cloudflare.build_bindings(access_token: "secret123")
    access_token_binding = bindings.find { |b| b[:name] == "ACCESS_TOKEN" }
    assert_equal "secret123", access_token_binding[:text]
    assert_equal "secret_text", access_token_binding[:type]
  end

  def test_build_bindings_merges_extra_bindings
    bindings = @cloudflare.build_bindings(access_token: "secret", extra: { "WS_URL" => "wss://example.com" })
    ws_url_binding = bindings.find { |b| b[:name] == "WS_URL" }
    assert_equal "wss://example.com", ws_url_binding[:text]
    assert_equal "plain_text", ws_url_binding[:type]
  end

  def test_build_bindings_converts_keys_to_strings
    bindings = @cloudflare.build_bindings(access_token: "secret", extra: { api_url: "https://api.example.com" })
    api_binding = bindings.find { |b| b[:name] == "api_url" }
    assert_equal "https://api.example.com", api_binding[:text]
  end
end
