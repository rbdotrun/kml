# frozen_string_literal: true

require "json"
require "fileutils"

module Kml
  class SessionStore
    STORE_DIR = ".kml"
    STORE_FILE = "sessions.json"

    class << self
      def path
        File.join(Dir.pwd, STORE_DIR, STORE_FILE)
      end

      def load
        return default_data unless File.exist?(path)

        JSON.parse(File.read(path), symbolize_names: true)
      rescue JSON::ParserError
        default_data
      end

      def save(data)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(data))
      end

      def all
        load[:sessions] || {}
      end

      def find(slug)
        sessions = all
        return nil unless sessions[slug.to_sym]

        sessions[slug.to_sym].merge(slug: slug.to_s)
      end

      def find_or_create(slug)
        existing = find(slug)
        return existing if existing

        create(slug)
      end

      def create(slug)
        data = load
        slug_sym = slug.to_sym

        raise Error, "Session '#{slug}' already exists" if data[:sessions][slug_sym]

        session = {
          uuid: SecureRandom.uuid,
          sandbox_id: nil,  # Set when sandbox is created
          access_token: SecureRandom.hex(32),
          created_at: Time.now.iso8601
        }

        data[:sessions][slug_sym] = session
        save(data)

        session.merge(slug: slug)
      end

      def update(slug, **attrs)
        data = load
        slug_sym = slug.to_sym

        return unless data[:sessions][slug_sym]

        data[:sessions][slug_sym].merge!(attrs)
        save(data)
      end

      def delete(slug)
        data = load
        data[:sessions].delete(slug.to_sym)
        save(data)
      end

      private

      def default_data
        { sessions: {} }
      end
    end
  end
end
