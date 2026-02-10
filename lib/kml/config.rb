# frozen_string_literal: true

require "yaml"
require "fileutils"

module Kml
  class Config
    KAMAL_CONFIG = "config/deploy.yml"
    SANDBOX_CONFIG = "config/deploy.sandbox.yml"
    SANDBOX_SECRETS = ".kamal/secrets.sandbox"

    attr_reader :production_config, :sandbox_config

    def initialize(root: Dir.pwd)
      @root = root
      @production_config = load_yaml(File.join(root, KAMAL_CONFIG))
    end

    def generate_sandbox(ip:)
      service_name = "#{@production_config['service']}-sandbox"

      @sandbox_config = {
        "service" => service_name,
        "image" => @production_config["image"],
        "servers" => {
          "web" => {
            "hosts" => [ip],
            "cmd" => sandbox_cmd,
            "options" => {
              "volume" => "/opt/#{@production_config['service']}:/rails"
            }
          }
        },
        "registry" => { "server" => "localhost:5001" },
        "proxy" => {
          "ssl" => false,
          "app_port" => 3000,
          "healthcheck" => {
            "path" => "/up",
            "interval" => 5,
            "timeout" => 60
          }
        },
        "builder" => { "arch" => "amd64" },
        "ssh" => { "user" => "deploy" },
        "env" => sandbox_env(ip),
        "volumes" => ["#{service_name.tr('-', '_')}_storage:/rails/storage"],
        "accessories" => sandbox_accessories(ip)
      }
    end

    def write_sandbox_config
      path = File.join(@root, SANDBOX_CONFIG)
      File.write(path, @sandbox_config.to_yaml)
      path
    end

    def write_sandbox_secrets
      FileUtils.mkdir_p(File.join(@root, ".kamal"))
      path = File.join(@root, SANDBOX_SECRETS)
      content = <<~SECRETS
        RAILS_MASTER_KEY=$(cat config/master.key)
        POSTGRES_PASSWORD=sandbox123
      SECRETS
      File.write(path, content)
      path
    end

    def service_name
      @production_config["service"]
    end

    def code_path
      "/opt/#{service_name}"
    end

    def ssh_keys
      # Kamal config can specify ssh.keys as array of key paths
      keys = @production_config.dig("ssh", "keys") || []
      keys = [keys] unless keys.is_a?(Array)
      keys.map { |k| File.expand_path(k) }
    end

    def ssh_public_key
      # Try keys from Kamal config first, then default
      key_paths = ssh_keys.map { |k| "#{k}.pub" }
      key_paths << File.expand_path("~/.ssh/id_rsa.pub")
      key_paths << File.expand_path("~/.ssh/id_ed25519.pub")

      key_path = key_paths.find { |p| File.exist?(p) }
      raise Error, "No SSH public key found" unless key_path

      File.read(key_path).strip
    end

    private

    def load_yaml(path)
      YAML.load_file(path, aliases: true)
    rescue Psych::AliasesNotEnabled
      YAML.load_file(path)
    end

    def sandbox_cmd
      db_host = "#{@production_config['service']}-sandbox-db"
      "bash -c 'while ! pg_isready -h #{db_host} -q; do sleep 1; done && bin/rails db:prepare && bin/rails server -b 0.0.0.0 -p 3000'"
    end

    def sandbox_env(ip)
      db_host = "#{@production_config['service']}-sandbox-db"
      {
        "clear" => {
          "RAILS_ENV" => "development",
          "RAILS_LOG_TO_STDOUT" => "1",
          "SOLID_QUEUE_IN_PUMA" => "",
          "POSTGRES_HOST" => db_host,
          "POSTGRES_USER" => "app",
          "POSTGRES_DB" => "app_sandbox",
          "POSTGRES_PORT" => "5432"
        },
        "secret" => %w[RAILS_MASTER_KEY POSTGRES_PASSWORD]
      }
    end

    def sandbox_accessories(ip)
      {
        "db" => {
          "image" => "postgres:17",
          "host" => ip,
          "port" => "5432:5432",
          "env" => {
            "clear" => {
              "POSTGRES_USER" => "app",
              "POSTGRES_DB" => "app_sandbox"
            },
            "secret" => ["POSTGRES_PASSWORD"]
          },
          "directories" => ["sandbox_data:/var/lib/postgresql/data"]
        }
      }
    end
  end
end
