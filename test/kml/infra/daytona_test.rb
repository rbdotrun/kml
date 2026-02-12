# frozen_string_literal: true

require "test_helper"

class Kml::Infra::DaytonaTest < Minitest::Test
  def setup
    @daytona = Kml::Infra::Daytona.new(api_key: "test-key")
  end

  def test_initialize_with_api_key
    daytona = Kml::Infra::Daytona.new(api_key: "my-key")

    assert_instance_of Kml::Infra::Daytona, daytona
  end

  def test_initialize_with_custom_endpoint
    daytona = Kml::Infra::Daytona.new(
      api_key: "key",
      endpoint: "https://custom.daytona.io/api"
    )

    assert_instance_of Kml::Infra::Daytona, daytona
  end

  def test_default_endpoint
    assert_equal "https://app.daytona.io/api", Kml::Infra::Daytona::DEFAULT_ENDPOINT
  end

  # Snapshot methods
  def test_responds_to_create_snapshot
    assert_respond_to @daytona, :create_snapshot
  end

  def test_responds_to_get_snapshot
    assert_respond_to @daytona, :get_snapshot
  end

  def test_responds_to_find_snapshot_by_name
    assert_respond_to @daytona, :find_snapshot_by_name
  end

  def test_responds_to_delete_snapshot
    assert_respond_to @daytona, :delete_snapshot
  end

  def test_responds_to_wait_for_snapshot
    assert_respond_to @daytona, :wait_for_snapshot
  end

  # Sandbox methods
  def test_responds_to_create_sandbox
    assert_respond_to @daytona, :create_sandbox
  end

  def test_responds_to_get_sandbox
    assert_respond_to @daytona, :get_sandbox
  end

  def test_responds_to_list_sandboxes
    assert_respond_to @daytona, :list_sandboxes
  end

  def test_responds_to_find_sandbox_by_name
    assert_respond_to @daytona, :find_sandbox_by_name
  end

  def test_responds_to_start_sandbox
    assert_respond_to @daytona, :start_sandbox
  end

  def test_responds_to_stop_sandbox
    assert_respond_to @daytona, :stop_sandbox
  end

  def test_responds_to_delete_sandbox
    assert_respond_to @daytona, :delete_sandbox
  end

  def test_responds_to_wait_for_sandbox
    assert_respond_to @daytona, :wait_for_sandbox
  end

  # Toolbox methods
  def test_responds_to_upload_file
    assert_respond_to @daytona, :upload_file
  end

  def test_responds_to_execute_command
    assert_respond_to @daytona, :execute_command
  end

  def test_responds_to_git_clone
    assert_respond_to @daytona, :git_clone
  end

  def test_responds_to_run_pty_command
    assert_respond_to @daytona, :run_pty_command
  end
end
