# frozen_string_literal: true

require "yaml"

module Kml
  module Cli
    class Config
      KML_CONFIG = ".kml.yml"
      KAMAL_SECRETS = ".kamal/secrets"

      AI_PROVIDERS = {
        "claude_code" => Kml::Ai::ClaudeCode
      }.freeze

      RUNTIMES = {
        "rails" => Kml::Runtime::Rails
      }.freeze

      attr_reader :install, :processes

      def initialize(root: Dir.pwd)
        @root = root
        config = load_yaml(File.join(root, KML_CONFIG))
        @install = config["install"] || []
        @processes = config["processes"] || {}
        @ai_config = config["ai"] || {}
        @runtime_name = config["runtime"] || "rails"
        @service_name = File.basename(root)
      end

      def service_name
        @service_name
      end

      # Load configuration from files and return a hash for library consumption
      #
      # @param root [String] Root directory (default: current directory)
      # @return [Hash] Configuration hash
      def self.from_files(root: Dir.pwd)
        config = new(root:)
        config.to_h
      end

      # Convert configuration to hash for library consumption
      def to_h
        {
          install: @install,
          processes: @processes,
          ai: {
            provider: ai_provider,
            env: ai_env
          },
          runtime: @runtime_name,
          git_repo: load_env_var("GIT_REPO_URL") || git_remote_url,
          git_token: load_env_var("GITHUB_TOKEN"),
          service_name: @service_name,
          cloudflare: {
            api_token: cloudflare_api_token,
            account_id: cloudflare_account_id,
            zone_id: cloudflare_zone_id,
            domain: load_env_var("CLOUDFLARE_DOMAIN")
          },
          daytona: {
            api_key: load_env_var("DAYTONA_API_KEY")
          }
        }
      end

      # Build AI provider instance from config
      #
      # @param config [Hash] Configuration hash with :ai key
      # @return [Kml::Ai::Base] AI provider instance
      def self.build_ai(config)
        provider_name = config.dig(:ai, :provider) || "claude_code"
        provider_class = AI_PROVIDERS[provider_name]
        raise Kml::Error, "Unknown AI provider: #{provider_name}" unless provider_class

        ai_env = config.dig(:ai, :env) || {}

        case provider_name
        when "claude_code"
          provider_class.new(
            auth_token: ai_env["ANTHROPIC_AUTH_TOKEN"],
            base_url: ai_env["ANTHROPIC_BASE_URL"]
          )
        else
          raise Kml::Error, "Unknown AI provider: #{provider_name}"
        end
      end

      # Build runtime instance from config
      #
      # @param config [Hash] Configuration hash with :runtime key
      # @return [Kml::Runtime::Base] Runtime instance
      def self.build_runtime(config)
        runtime_name = config[:runtime] || "rails"
        runtime_class = RUNTIMES[runtime_name]
        raise Kml::Error, "Unknown runtime: #{runtime_name}" unless runtime_class

        runtime_class.new
      end

      # Build Daytona client from config
      #
      # @param config [Hash] Configuration hash with :daytona key
      # @return [Kml::Infra::Daytona] Daytona client
      def self.build_daytona(config)
        api_key = config.dig(:daytona, :api_key)
        raise Kml::Error, "DAYTONA_API_KEY not set. Run 'kml init' or set in .env" unless api_key

        Kml::Infra::Daytona.new(api_key:)
      end

      # Build Cloudflare client from config
      #
      # @param config [Hash] Configuration hash with :cloudflare key
      # @return [Kml::Infra::Cloudflare, nil] Cloudflare client or nil if not configured
      def self.build_cloudflare(config)
        cf = config[:cloudflare] || {}
        return nil unless cf[:api_token] && cf[:zone_id]

        Kml::Infra::Cloudflare.new(
          api_token: cf[:api_token],
          account_id: cf[:account_id],
          zone_id: cf[:zone_id],
          domain: cf[:domain]
        )
      end

      def code_path
        "/home/deploy/app"
      end

      def ssh_public_key
        key_paths = [
          File.expand_path("~/.ssh/id_ed25519.pub"),
          File.expand_path("~/.ssh/id_rsa.pub")
        ]

        key_path = key_paths.find { |p| File.exist?(p) }
        raise Kml::Error, "No SSH public key found" unless key_path

        File.read(key_path).strip
      end

      def cloudflare_account_id
        load_env_var("CLOUDFLARE_ACCOUNT_ID")
      end

      def cloudflare_api_token
        load_env_var("CLOUDFLARE_API_TOKEN")
      end

      def cloudflare_zone_id
        load_env_var("CLOUDFLARE_ZONE_ID")
      end

      private

        def ai_provider
          @ai_config["provider"] || "claude_code"
        end

        def ai_env
          raw_env = @ai_config["env"] || {}

          # Handle array format (- KEY: value) by converting to hash
          env = if raw_env.is_a?(Array)
            raw_env.reduce({}) { |h, item| h.merge(item) }
          else
            raw_env
          end

          # Add defaults from .env
          env["ANTHROPIC_AUTH_TOKEN"] ||= load_env_var("ANTHROPIC_AUTH_TOKEN")
          env["ANTHROPIC_BASE_URL"] ||= load_env_var("ANTHROPIC_BASE_URL")

          # Expand ${VAR} references
          env.transform_values do |v|
            next v unless v.is_a?(String)
            v.gsub(/\$\{(\w+)\}/) { load_env_var($1) || ENV[$1] }
          end.compact
        end

        def git_remote_url
          url = `git remote get-url origin 2>/dev/null`.strip
          url.empty? ? nil : url
        end

        def load_yaml(path)
          raise Kml::Error, "#{KML_CONFIG} not found" unless File.exist?(path)
          YAML.load_file(path)
        end

        def load_env_var(name)
          return ENV[name] if ENV[name] && !ENV[name].empty?

          env_path = File.join(@root, ".env")
          return nil unless File.exist?(env_path)

          File.read(env_path)[/^#{name}=(.+)$/, 1]&.strip
        end

        def load_kamal_secret(name)
          path = File.join(@root, KAMAL_SECRETS)
          return nil unless File.exist?(path)

          File.read(path)[/^#{name}=(.+)$/, 1]&.strip
        end
    end
  end
end
