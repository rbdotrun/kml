# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class Kml::Core::StoreTest < Minitest::Test
  def setup
    @original_pwd = Dir.pwd
    @tmpdir = Dir.mktmpdir
    Dir.chdir(@tmpdir)
  end

  def teardown
    Dir.chdir(@original_pwd)
    FileUtils.rm_rf(@tmpdir)
  end

  def test_all_returns_empty_hash_when_no_sessions
    assert_empty(Kml::Core::Store.all)
  end

  def test_find_returns_nil_when_not_found
    assert_nil Kml::Core::Store.find("nonexistent")
  end

  def test_create_generates_uuid
    # Sessions don't have UUIDs, but they have access_tokens
    result = Kml::Core::Store.create("test-session")

    assert result[:access_token]
    assert_match(/\A[a-f0-9]{64}\z/, result[:access_token])
  end

  def test_create_generates_access_token
    result = Kml::Core::Store.create("my-session")

    assert_kind_of String, result[:access_token]
    assert_equal 64, result[:access_token].length
  end

  def test_create_stores_session
    Kml::Core::Store.create("stored-session")
    found = Kml::Core::Store.find("stored-session")

    assert found
    assert_equal "stored-session", found[:slug]
    assert found[:created_at]
  end

  def test_create_raises_for_duplicate
    Kml::Core::Store.create("duplicate")

    assert_raises(Kml::Error) do
      Kml::Core::Store.create("duplicate")
    end
  end

  def test_update_merges_attributes
    Kml::Core::Store.create("update-test")
    Kml::Core::Store.update("update-test", sandbox_id: "sb-123")

    found = Kml::Core::Store.find("update-test")

    assert_equal "sb-123", found[:sandbox_id]
  end

  def test_update_ignores_missing_session
    # Should not raise
    Kml::Core::Store.update("nonexistent", sandbox_id: "test")
  end

  def test_delete_removes_session
    Kml::Core::Store.create("to-delete")

    assert Kml::Core::Store.find("to-delete")

    Kml::Core::Store.delete("to-delete")

    assert_nil Kml::Core::Store.find("to-delete")
  end

  def test_add_conversation_appends_to_list
    Kml::Core::Store.create("conv-test")
    Kml::Core::Store.add_conversation("conv-test", uuid: "uuid-1", prompt: "first prompt")
    Kml::Core::Store.add_conversation("conv-test", uuid: "uuid-2", prompt: "second prompt")

    convs = Kml::Core::Store.conversations("conv-test")

    assert_equal 2, convs.size
    assert_equal "uuid-1", convs[0][:uuid]
    assert_equal "uuid-2", convs[1][:uuid]
  end

  def test_conversations_returns_session_conversations
    Kml::Core::Store.create("list-convs")
    Kml::Core::Store.add_conversation("list-convs", uuid: "abc", prompt: "test")

    convs = Kml::Core::Store.conversations("list-convs")

    assert_equal 1, convs.size
    assert_equal "abc", convs[0][:uuid]
  end

  def test_conversations_returns_empty_for_missing_session
    assert_empty Kml::Core::Store.conversations("nonexistent")
  end

  def test_update_conversation_updates_prompt
    Kml::Core::Store.create("update-conv")
    Kml::Core::Store.add_conversation("update-conv", uuid: "conv-123", prompt: "original")
    Kml::Core::Store.update_conversation("update-conv", uuid: "conv-123", prompt: "updated prompt")

    convs = Kml::Core::Store.conversations("update-conv")

    assert_equal "updated prompt", convs[0][:last_prompt]
  end
end
