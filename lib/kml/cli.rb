# frozen_string_literal: true

require "thor"

module Kml
  class CLI < Thor
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

    private

    def sandbox
      token = ENV.fetch("HETZNER_API_TOKEN") { load_env_token }
      hetzner = Hetzner.new(token: token)
      config = Config.new
      Sandbox.new(hetzner: hetzner, config: config)
    end

    def load_env_token
      return unless File.exist?(".env")

      File.read(".env")[/HETZNER_API_TOKEN=(.+)/, 1]
    end
  end
end
