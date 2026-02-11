# frozen_string_literal: true

require "thor"

module Kml
  class CLI < Thor
    desc "init", "Setup credentials for kml"
    def init
      Setup.new.run
    end

    desc "deploy", "Provision server and deploy sandbox"
    def deploy
      sandbox.deploy
    end

    desc "destroy", "Teardown sandbox server"
    def destroy
      sandbox.destroy
    end

    desc "exec COMMAND", "Execute command in sandbox container"
    def exec(command)
      sandbox.exec(command)
    end

    desc "ssh", "SSH into sandbox server"
    def ssh
      sandbox.ssh
    end

    desc "snapshot [SERVER]", "Create base image snapshot (SERVER: blank=fresh, or server name to snapshot)"
    def snapshot(server_name = nil)
      if server_name
        sandbox.snapshot_from_server(server_name)
      else
        sandbox.snapshot_create
      end
    end

    desc "snapshot_delete", "Delete the base image snapshot"
    def snapshot_delete
      sandbox.snapshot_delete
    end

    desc "session SUBCOMMAND ...ARGS", "Manage Claude sessions"
    subcommand "session", SessionCLI

    private

    def sandbox
      token = ENV.fetch("HETZNER_API_TOKEN") { load_env_var("HETZNER_API_TOKEN") }
      raise Error, "HETZNER_API_TOKEN not set. Run 'kml init' first." unless token

      hetzner = Hetzner.new(token: token)
      config = Config.new
      Sandbox.new(hetzner: hetzner, config: config)
    end

    def load_env_var(name)
      return unless File.exist?(".env")

      File.read(".env")[/#{name}=(.+)/, 1]&.strip
    end
  end
end
