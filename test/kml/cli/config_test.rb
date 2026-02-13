# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class Kml::Cli::ConfigTest < Minitest::Test
  def setup
    @original_pwd = Dir.pwd
    @tmpdir = Dir.mktmpdir("kml-config-test")
    Dir.chdir(@tmpdir)

    # Create minimal .kml.yml
    File.write(".kml.yml", <<~YAML)
      install:
        - bundle install
        - bin/rails db:prepare
      processes:
        web: bin/rails server -b 0.0.0.0
        css: bin/rails tailwindcss:watch
    YAML
  end

  def teardown
    Dir.chdir(@original_pwd)
    FileUtils.rm_rf(@tmpdir)
  end

  def test_from_files_reads_kml_yml
    config = Kml::Cli::Config.from_files(root: @tmpdir)

    commands = config[:install].map { |i| i["command"] }
    assert_includes commands, "bundle install"
    assert_includes commands, "bin/rails db:prepare"
  end

  def test_from_files_returns_install_array
    config = Kml::Cli::Config.from_files(root: @tmpdir)

    assert_kind_of Array, config[:install]
    assert_equal 2, config[:install].size
  end

  def test_from_files_returns_processes_hash
    config = Kml::Cli::Config.from_files(root: @tmpdir)

    assert_kind_of Hash, config[:processes]
    assert config[:processes]["web"]
    assert config[:processes]["css"]
  end

  def test_from_files_returns_ai_config
    config = Kml::Cli::Config.from_files(root: @tmpdir)

    assert config[:ai]
    assert_equal "claude_code", config[:ai][:provider]
  end

  def test_from_files_with_ai_provider_config
    File.write(".kml.yml", <<~YAML)
      install: []
      processes: {}
      ai:
        provider: claude_code
    YAML

    config = Kml::Cli::Config.from_files(root: @tmpdir)

    assert_equal "claude_code", config[:ai][:provider]
  end

  def test_from_files_expands_env_vars
    File.write(".env", "TEST_VAR=expanded_value\n")
    File.write(".kml.yml", <<~YAML)
      install: []
      processes: {}
      ai:
        provider: claude_code
        env:
          CUSTOM_VAR: "${TEST_VAR}"
    YAML

    config = Kml::Cli::Config.from_files(root: @tmpdir)

    assert_equal "expanded_value", config[:ai][:env]["CUSTOM_VAR"]
  end

  def test_build_ai_creates_claude_code
    config = {
      ai: {
        provider: "claude_code",
        env: { "ANTHROPIC_AUTH_TOKEN" => "test-token" }
      }
    }

    ai = Kml::Cli::Config.build_ai(config)

    assert_instance_of Kml::Ai::ClaudeCode, ai
  end

  def test_build_ai_raises_for_unknown_provider
    config = { ai: { provider: "unknown_ai" } }

    assert_raises(Kml::Error) do
      Kml::Cli::Config.build_ai(config)
    end
  end

  def test_build_runtime_creates_rails
    config = { runtime: "rails" }

    runtime = Kml::Cli::Config.build_runtime(config)

    assert_instance_of Kml::Runtime::Rails, runtime
  end

  def test_build_runtime_raises_for_unknown_runtime
    config = { runtime: "unknown_runtime" }

    assert_raises(Kml::Error) do
      Kml::Cli::Config.build_runtime(config)
    end
  end

  def test_build_daytona_creates_client
    config = { daytona: { api_key: "test-key" } }

    daytona = Kml::Cli::Config.build_daytona(config)

    assert_instance_of Kml::Infra::Daytona, daytona
  end

  def test_build_daytona_raises_without_api_key
    config = { daytona: { api_key: nil } }

    assert_raises(Kml::Error) do
      Kml::Cli::Config.build_daytona(config)
    end
  end

  def test_build_cloudflare_returns_nil_without_config
    config = { cloudflare: { api_token: nil } }

    result = Kml::Cli::Config.build_cloudflare(config)

    assert_nil result
  end

  def test_build_cloudflare_creates_client
    config = {
      cloudflare: {
        api_token: "token",
        account_id: "account",
        zone_id: "zone",
        domain: "example.com"
      }
    }

    cf = Kml::Cli::Config.build_cloudflare(config)

    assert_instance_of Kml::Infra::Cloudflare, cf
  end

  def test_service_name_from_directory
    config = Kml::Cli::Config.new(root: @tmpdir)
    # Service name should be the basename of the root directory
    assert_equal File.basename(@tmpdir), config.service_name
  end
end
