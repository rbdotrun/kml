# frozen_string_literal: true

require "test_helper"

class Kml::Core::SandboxTest < Minitest::Test
  def setup
    @runtime = Kml::Runtime::Rails.new
  end

  def build_sandbox(daytona: nil, cloudflare: nil, **overrides)
    defaults = {
      daytona: daytona || TestStub.new,
      runtime: @runtime,
      service_name: "my-app",
      cloudflare:
    }
    Kml::Core::Sandbox.new(**defaults.merge(overrides))
  end

  def test_snapshot_name_includes_service_name
    sandbox = build_sandbox(service_name: "test-service")

    assert_equal "kml-test-service", sandbox.snapshot_name
  end

  def test_code_path
    sandbox = build_sandbox

    assert_equal "/home/daytona/app", sandbox.code_path
  end

  def test_deploy_creates_snapshot_when_missing
    daytona = TestStub.new(
      find_snapshot_by_name: nil,
      create_snapshot: { "id" => "snap-123" },
      wait_for_snapshot: {}
    )

    sandbox = build_sandbox(daytona:)
    out, = capture_io do
      sandbox.deploy
    end

    assert_includes out, "Snapshot ready"
    assert_equal 1, daytona.calls(:create_snapshot).size
  end

  def test_deploy_reuses_existing_snapshot
    daytona = TestStub.new(
      find_snapshot_by_name: { "id" => "existing" }
    )

    sandbox = build_sandbox(daytona:)
    out, = capture_io do
      sandbox.deploy
    end

    assert_includes out, "exists"
    assert_equal 0, daytona.calls(:create_snapshot).size
  end

  def test_destroy_deletes_all_sessions
    sessions = {
      "session1" => { sandbox_id: "sb-1" },
      "session2" => { sandbox_id: "sb-2" }
    }

    daytona = TestStub.new(
      delete_sandbox: nil
    )
    cloudflare = TestStub.new(
      domain: "example.com",
      delete_worker: nil
    )

    deleted = []
    sandbox = build_sandbox(daytona:, cloudflare:)
    capture_io do
      sandbox.destroy(
        sessions:,
        delete_session: ->(slug) { deleted << slug }
      )
    end

    assert_equal %w[session1 session2], deleted
    assert_equal 2, daytona.calls(:delete_sandbox).size
  end

  def test_snapshot_create_rebuilds_snapshot
    daytona = TestStub.new(
      find_snapshot_by_name: { "id" => "old" },
      delete_snapshot: nil,
      create_snapshot: { "id" => "new" },
      wait_for_snapshot: {}
    )

    sandbox = build_sandbox(daytona:)
    capture_io do
      sandbox.snapshot_create
    end

    assert_equal 1, daytona.calls(:delete_snapshot).size
    assert_equal 1, daytona.calls(:create_snapshot).size
  end

  def test_snapshot_delete_removes_snapshot
    daytona = TestStub.new(
      find_snapshot_by_name: { "id" => "snap-123" },
      delete_snapshot: nil
    )

    sandbox = build_sandbox(daytona:)
    capture_io do
      sandbox.snapshot_delete
    end

    assert_equal 1, daytona.calls(:delete_snapshot).size
  end

  def test_snapshot_delete_handles_missing_snapshot
    daytona = TestStub.new(
      find_snapshot_by_name: nil
    )

    sandbox = build_sandbox(daytona:)
    out, = capture_io do
      sandbox.snapshot_delete
    end

    assert_includes out, "No snapshot found"
    assert_equal 0, daytona.calls(:delete_snapshot).size
  end
end
