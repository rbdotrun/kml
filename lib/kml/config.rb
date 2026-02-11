# frozen_string_literal: true

require "yaml"

module Kml
  class Config
    KML_CONFIG = ".kml.yml"
    KAMAL_SECRETS = ".kamal/secrets"
    KAMAL_TUNNEL_CONFIG = ".kamal/tunnel/config.yml"

    attr_reader :install, :processes

    def initialize(root: Dir.pwd)
      @root = root
      config = load_yaml(File.join(root, KML_CONFIG))
      @install = config["install"] || []
      @processes = config["processes"] || {}
      @service_name = File.basename(root)
    end

    def service_name
      @service_name
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
      raise Error, "No SSH public key found" unless key_path

      File.read(key_path).strip
    end

    def tunnel_token
      # Check .env first, then .kamal/secrets
      load_env_var("TUNNEL_TOKEN") || load_kamal_secret("TUNNEL_TOKEN")
    end

    def tunnel_hostname
      domain = load_env_var("CLOUDFLARE_DOMAIN")
      return nil unless domain

      "#{service_name}-sandbox.#{domain}"
    end

    def tunnel_id
      path = File.join(@root, KAMAL_TUNNEL_CONFIG)
      return nil unless File.exist?(path)

      config = YAML.load_file(path)
      config["tunnel"]
    end

    def tunnel_credentials
      path = File.join(@root, ".kamal/tunnel/credentials.json")
      return nil unless File.exist?(path)

      File.read(path)
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

    def load_yaml(path)
      raise Error, "#{KML_CONFIG} not found" unless File.exist?(path)
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
