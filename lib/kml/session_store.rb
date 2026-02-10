# frozen_string_literal: true

require "json"
require "fileutils"

module Kml
  class SessionStore
    STORE_DIR = ".kml"
    STORE_FILE = "sessions.json"
    STARTING_PORT = 3001

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

      def create(slug)
        data = load
        slug_sym = slug.to_sym

        raise Error, "Session '#{slug}' already exists" if data[:sessions][slug_sym]

        session = {
          uuid: SecureRandom.uuid,
          branch: "kml/#{slug}",
          port: data[:next_port],
          database: "app_session_#{slug.gsub('-', '_')}",
          created_at: Time.now.iso8601
        }

        data[:sessions][slug_sym] = session
        data[:next_port] += 1
        save(data)

        session.merge(slug: slug)
      end

      def delete(slug)
        data = load
        data[:sessions].delete(slug.to_sym)
        save(data)
      end

      private

      def default_data
        { sessions: {}, next_port: STARTING_PORT }
      end
    end
  end
end
