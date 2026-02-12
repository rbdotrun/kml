# frozen_string_literal: true

module Kml
  module Core
    class Sandbox
      # Initialize sandbox manager
      #
      # @param daytona [Kml::Infra::Daytona] Daytona API client
      # @param runtime [Kml::Runtime::Base] Runtime for dockerfile
      # @param service_name [String] Service name for naming resources
      # @param cloudflare [Kml::Infra::Cloudflare, nil] Cloudflare client for cleanup
      def initialize(daytona:, runtime:, service_name:, cloudflare: nil)
        @daytona = daytona
        @runtime = runtime
        @service_name = service_name
        @cloudflare = cloudflare
      end

      def snapshot_name
        "kml-#{@service_name}"
      end

      def code_path
        "/home/daytona/app"
      end

      # Execute command in sandbox via Daytona API
      def exec_in_sandbox(sandbox_id, cmd, timeout: 300)
        @daytona.execute_command(
          sandbox_id:,
          command: cmd,
          timeout:
        )
      end

      # Deploy the base snapshot (create if missing)
      def deploy
        print "[1/2] Creating snapshot..."
        snapshot = @daytona.find_snapshot_by_name(snapshot_name)

        if snapshot
          puts " exists"
        else
          puts ""
          print "    Building..."
          result = @daytona.create_snapshot(
            name: snapshot_name,
            dockerfile_content: @runtime.dockerfile,
            cpu: 2,
            memory: 4,
            disk: 10
          )
          snapshot_id = result["id"]
          @daytona.wait_for_snapshot(snapshot_id, timeout: 600)
          puts " done"
        end

        puts "[2/2] Snapshot ready: #{snapshot_name}"
        puts "\n Sandbox ready. Use 'kml session new <slug>' to create sessions."
      end

      # Destroy all sandboxes for this service (preserves snapshot)
      #
      # @param sessions [Hash] Session data from store
      # @param delete_session [Proc] Callback to delete session from store
      def destroy(sessions:, delete_session:)
        if sessions.any?
          puts "Deleting #{sessions.size} session(s)..."
          sessions.each do |slug, data|
            print "  #{slug}..."
            if data[:sandbox_id]
              begin
                @daytona.delete_sandbox(data[:sandbox_id])
              rescue StandardError
                # Ignore errors
              end
            end

            if @cloudflare
              worker_name = "kml-#{@service_name}-#{slug}"
              hostname = "#{slug}.#{@cloudflare.domain}"
              @cloudflare.delete_worker(worker_name:, hostname:)
              @cloudflare.delete_tunnel(tunnel_id: data[:tunnel_id]) if data[:tunnel_id]
            end

            delete_session.call(slug.to_s)
            puts " done"
          end
        end

        puts " All sandboxes destroyed (snapshot preserved)"
      end

      # Create or rebuild the base snapshot
      def snapshot_create
        puts "Creating snapshot #{snapshot_name}..."

        # Delete existing if any
        existing = @daytona.find_snapshot_by_name(snapshot_name)
        if existing
          print "Deleting existing snapshot..."
          @daytona.delete_snapshot(existing["id"])
          sleep 10 # Wait for deletion to propagate
          puts " done"
        end

        print "Building..."
        result = @daytona.create_snapshot(
          name: snapshot_name,
          dockerfile_content: @runtime.dockerfile,
          cpu: 2,
          memory: 4,
          disk: 10
        )
        snapshot_id = result["id"]
        @daytona.wait_for_snapshot(snapshot_id, timeout: 600)
        puts " done"

        puts "\n Snapshot '#{snapshot_name}' created"
      end

      # Delete the base snapshot
      def snapshot_delete
        snapshot = @daytona.find_snapshot_by_name(snapshot_name)
        if snapshot
          @daytona.delete_snapshot(snapshot["id"])
          puts " Snapshot deleted"
        else
          puts "No snapshot found."
        end
      end
    end
  end
end
