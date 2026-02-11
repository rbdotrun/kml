# frozen_string_literal: true

require "thor"

module Kml
  class CLI < Thor
    desc "init", "Setup credentials for kml"
    def init
      Setup.new.run
    end

    desc "deploy", "Create Daytona snapshot for sandbox"
    def deploy
      sandbox.deploy
    end

    desc "destroy", "Delete all sandboxes (keeps snapshot)"
    def destroy
      sandbox.destroy
    end

    desc "snapshot", "Create/rebuild the base snapshot"
    def snapshot
      sandbox.snapshot_create
    end

    desc "snapshot_delete", "Delete the base snapshot"
    def snapshot_delete
      sandbox.snapshot_delete
    end

    desc "session SUBCOMMAND ...ARGS", "Manage Claude sessions"
    subcommand "session", SessionCLI

    private

    def sandbox
      api_key = ENV.fetch("DAYTONA_API_KEY") { load_env_var("DAYTONA_API_KEY") }
      raise Error, "DAYTONA_API_KEY not set. Run 'kml init' or set in .env" unless api_key

      daytona = Daytona.new(api_key: api_key)
      config = Config.new
      Sandbox.new(daytona: daytona, config: config)
    end

    def load_env_var(name)
      return unless File.exist?(".env")

      File.read(".env")[/#{name}=(.+)/, 1]&.strip
    end
  end
end
