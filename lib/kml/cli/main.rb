# frozen_string_literal: true

require "thor"

module Kml
  module Cli
    class Main < Thor
      desc "init", "Setup credentials for kml"
      def init
        Kml::Setup.new.run
      end

      desc "deploy", "Create Daytona snapshot for sandbox"
      def deploy
        sandbox.deploy
      end

      desc "destroy", "Delete all sandboxes (keeps snapshot)"
      def destroy
        sessions = Kml::Core::Store.all
        sandbox.destroy(
          sessions:,
          delete_session: ->(slug) { Kml::Core::Store.delete(slug) }
        )
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
      subcommand "session", Session

      private

        def sandbox
          config = Config.from_files
          daytona = Config.build_daytona(config)
          runtime = Config.build_runtime(config)
          cloudflare = Config.build_cloudflare(config)

          Kml::Core::Sandbox.new(
            daytona:,
            runtime:,
            service_name: config[:service_name],
            cloudflare:
          )
        end
    end
  end
end
