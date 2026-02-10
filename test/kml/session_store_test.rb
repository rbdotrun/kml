# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

class SessionStoreTest < Minitest::Test
  def setup
    @tmp_dir = Dir.mktmpdir
    @original_pwd = Dir.pwd
    Dir.chdir(@tmp_dir)
  end

  def teardown
    Dir.chdir(@original_pwd)
    FileUtils.rm_rf(@tmp_dir)
  end

  def test_create_session
    session = Kml::SessionStore.create("test-feature")

    assert_equal "test-feature", session[:slug]
    assert_match(/^[0-9a-f-]{36}$/, session[:uuid])
    assert_equal 3001, session[:port]
    assert_equal "kml/test-feature", session[:branch]
    assert_equal "app_session_test_feature", session[:database]
    assert session[:created_at]
  end

  def test_find_session
    Kml::SessionStore.create("my-session")
    found = Kml::SessionStore.find("my-session")

    assert found
    assert_equal "my-session", found[:slug]
    assert_equal "kml/my-session", found[:branch]
  end

  def test_find_nonexistent_session
    found = Kml::SessionStore.find("nonexistent")
    assert_nil found
  end

  def test_port_increment
    Kml::SessionStore.create("s1")
    s2 = Kml::SessionStore.create("s2")
    s3 = Kml::SessionStore.create("s3")

    assert_equal 3002, s2[:port]
    assert_equal 3003, s3[:port]
  end

  def test_delete_session
    Kml::SessionStore.create("to-delete")
    Kml::SessionStore.delete("to-delete")

    assert_nil Kml::SessionStore.find("to-delete")
  end

  def test_all_sessions
    Kml::SessionStore.create("session-a")
    Kml::SessionStore.create("session-b")

    all = Kml::SessionStore.all
    assert_equal 2, all.size
    assert all[:"session-a"]
    assert all[:"session-b"]
  end

  def test_duplicate_session_raises_error
    Kml::SessionStore.create("dupe")

    assert_raises(Kml::Error) do
      Kml::SessionStore.create("dupe")
    end
  end

  def test_creates_store_directory
    refute File.exist?(".kml")
    Kml::SessionStore.create("first")
    assert File.exist?(".kml/sessions.json")
  end
end
