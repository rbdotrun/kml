# frozen_string_literal: true

require "securerandom"

module Kml
  module Core
    class InstallError < StandardError; end

    class Session
      attr_reader :slug, :sandbox_id, :access_token, :created_at, :uuid, :tunnel_id, :tunnel_token

      # Initialize a session with all dependencies injected
      #
      # @param slug [String] Unique session identifier
      # @param ai [Kml::Ai::Base] AI backend instance
      # @param daytona [Kml::Infra::Daytona] Daytona API client
      # @param cloudflare [Kml::Infra::Cloudflare] Cloudflare API client
      # @param git_repo [String] Git repository URL
      # @param git_branch [String] Git branch to clone (default: "main")
      # @param git_token [String, nil] GitHub token for private repos
      # @param install [Array<String>] Install commands to run
      # @param processes [Hash<String, String>] Process name => command pairs
      # @param env [Hash<String, String>] Environment variables
      # @param service_name [String] Service name for naming resources
      # @param sandbox_id [String, nil] Existing sandbox ID (for resuming)
      # @param access_token [String, nil] Existing access token (for resuming)
      # @param created_at [String, nil] Creation timestamp (for resuming)
      # @param tunnel_id [String, nil] Existing tunnel ID (for resuming)
      # @param tunnel_token [String, nil] Existing tunnel token (for resuming)
      # @param worker_files [Hash<String, String>] Extra files to upload to worker (filename => content)
      # @param worker_bindings [Hash<String, String>] Extra env bindings for worker
      # @param worker_injection [String, nil] HTML to inject into responses
      def initialize(
        slug:,
        ai:,
        daytona:,
        cloudflare:,
        git_repo:,
        git_branch: "main",
        git_token: nil,
        install: [],
        processes: {},
        env: {},
        service_name:,
        sandbox_id: nil,
        access_token: nil,
        created_at: nil,
        tunnel_id: nil,
        tunnel_token: nil,
        worker_files: {},
        worker_bindings: {},
        worker_injection: nil
      )
        @slug = slug
        @ai = ai
        @daytona = daytona
        @cloudflare = cloudflare
        @git_repo = git_repo
        @git_branch = git_branch
        @git_token = git_token
        @install = install
        @processes = processes
        @env = env
        @service_name = service_name
        @sandbox_id = sandbox_id
        @access_token = access_token || SecureRandom.hex(32)
        @created_at = created_at || Time.now.iso8601
        @uuid = SecureRandom.uuid
        @tunnel_id = tunnel_id
        @tunnel_token = tunnel_token
        @worker_files = worker_files
        @worker_bindings = worker_bindings
        @worker_injection = worker_injection
      end

      def public_url
        return nil unless @cloudflare&.domain
        "https://#{@slug}.#{@cloudflare.domain}"
      end

      def code_path
        "/home/daytona/app"
      end

      def running?
        return false unless @sandbox_id

        begin
          sandbox = @daytona.get_sandbox(@sandbox_id)
          %w[started running].include?(sandbox["state"])
        rescue StandardError
          false
        end
      end

      # Fetch process statuses from overmind
      # @return [Array<Hash>] Array of { name:, status: } hashes
      def process_statuses
        return [] unless @sandbox_id

        result = @daytona.execute_command(
          sandbox_id: @sandbox_id,
          command: "cd #{code_path} && overmind status 2>/dev/null || echo ''",
          timeout: 10
        )

        parse_overmind_status(result["result"].to_s)
      rescue StandardError
        []
      end

      # Restart a specific process managed by overmind
      # @param process_name [String] Name of the process to restart
      # @return [Boolean] true if successful
      def restart_process(process_name)
        return false unless @sandbox_id

        @daytona.execute_command(
          sandbox_id: @sandbox_id,
          command: "cd #{code_path} && overmind restart #{process_name}",
          timeout: 30
        )
        true
      rescue StandardError
        false
      end

      # Create sandbox and start the session
      def start!(&block)
        sandbox_name = "kml-#{@service_name}-#{@slug}"

        # Delete existing sandbox if any
        existing = @daytona.find_sandbox_by_name(sandbox_name)
        if existing
          print "Found existing sandbox, deleting..."
          begin
            @daytona.delete_sandbox(existing["id"])
            sleep 2
          rescue StandardError => e
            puts " warning: #{e.message}"
          end
          puts " done"
        end

        puts "Creating Daytona sandbox..."

        sandbox_result = @daytona.create_sandbox(
          snapshot: snapshot_name,
          name: sandbox_name,
          auto_stop_interval: 0,
          public: false
        )

        @sandbox_id = sandbox_result["id"]
        block&.call(:sandbox_created, @sandbox_id)

        print "Waiting for sandbox..."
        @daytona.wait_for_sandbox(@sandbox_id)
        puts " ready"

        clone_repo
        setup_tunnel
        write_procfile
        start_postgres
        run_install_commands(&block)
        start_app
        start_tunnel
        deploy_worker

        puts ""
        puts "Session '#{@slug}' ready"
        puts "URL: #{public_url}?token=#{@access_token}"
        puts ""
        puts "Run: kml session prompt #{@slug} \"your prompt\""
      end

      # Run AI coding assistant with a prompt
      #
      # @param prompt [String] The prompt to send
      # @param resume [Boolean] Whether to resume the previous conversation
      # @param session_id [String, nil] Session ID for conversation continuity
      # @yield [String] Yields each line of JSON output
      def run!(prompt:, resume: false, session_id: nil, &block)
        raise Kml::Error, "Prompt required" if prompt.nil? || prompt.empty?

        unless running?
          raise Kml::Error, "Sandbox not running. Run 'kml session new #{@slug}' first."
        end

        executor = method(:exec_pty)
        @ai.run(
          prompt:,
          session_id: session_id || @uuid,
          resume:,
          cwd: code_path,
          executor:
        ) do |line|
          puts line
          $stdout.flush
          block.call(line) if block
        end
      end

      def stop!
        return unless @sandbox_id

        begin
          @daytona.stop_sandbox(@sandbox_id)
          puts "Session '#{@slug}' stopped."
        rescue StandardError => e
          puts "Warning: #{e.message}"
        end
      end

      def delete!
        stop!

        if @sandbox_id
          # Wait for sandbox to finish stopping before deleting
          wait_for_sandbox_stopped

          begin
            @daytona.delete_sandbox(@sandbox_id)
          rescue StandardError => e
            puts "Warning: failed to delete sandbox: #{e.message}"
          end
        end

        if @cloudflare
          worker_name = "kml-#{@service_name}-#{@slug}"
          hostname = "#{@slug}.#{@cloudflare.domain}"
          @cloudflare.delete_worker(worker_name:, hostname:)

          # Delete the session-specific tunnel
          @cloudflare.delete_tunnel(tunnel_id: @tunnel_id) if @tunnel_id
        end
      end

      # Serialize session state for persistence
      def to_h
        {
          slug: @slug,
          sandbox_id: @sandbox_id,
          access_token: @access_token,
          created_at: @created_at,
          tunnel_id: @tunnel_id,
          tunnel_token: @tunnel_token
        }
      end

      private

        def wait_for_sandbox_stopped(timeout: 30)
          return unless @sandbox_id

          print "Waiting for sandbox to stop..."
          start = Time.now
          loop do
            sandbox = @daytona.get_sandbox(@sandbox_id)
            state = sandbox["state"]
            break if %w[stopped error].include?(state)
            break if Time.now - start > timeout

            print "."
            sleep 1
          end
          puts " done"
        rescue StandardError
          puts " skipped"
        end

        def snapshot_name
          "kml-#{@service_name}"
        end

        def db_name
          @slug.gsub("-", "_") + "_dev"
        end

        def mise_prefix
          'export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH" &&'
        end

        def exec_sh(cmd)
          @daytona.execute_command(
            sandbox_id: @sandbox_id,
            command: "bash -c #{cmd.inspect}",
            timeout: 600
          )
        end

        def exec_pty(cmd, &block)
          @daytona.run_pty_command(
            sandbox_id: @sandbox_id,
            command: cmd,
            timeout: 600,
            &block
          )
        end

        def clone_repo
          return unless @git_repo

          print "Cloning repository..."
          repo_url = ssh_to_https(@git_repo)

          @daytona.git_clone(
            sandbox_id: @sandbox_id,
            url: repo_url,
            path: code_path,
            branch: @git_branch,
            username: @git_token ? "x-access-token" : nil,
            password: @git_token
          )
          puts " done"
        end

        # Create a session-specific tunnel to avoid routing conflicts
        # Each session gets its own tunnel with cloudflare-managed config
        # Run with: cloudflared tunnel run --token <TOKEN>
        def setup_tunnel
          return unless @cloudflare

          print "Setting up tunnel..."

          hostname = "#{@slug}.#{@cloudflare.domain}"

          # Create a new tunnel for this session (unless resuming with existing tunnel)
          unless @tunnel_id
            tunnel_name = "kml-#{@service_name}-#{@slug}"
            result = @cloudflare.create_tunnel(tunnel_name:, hostname:)
            @tunnel_id = result[:tunnel_id]
            @tunnel_token = result[:token]
          end

          @cloudflare.ensure_tunnel_dns(hostname:, tunnel_id: @tunnel_id)
          puts " done"
        end

        def write_procfile
          print "Configuring processes..."
          procfile_content = @processes.map { |name, cmd| "#{name}: #{cmd}" }.join("\n")
          @daytona.upload_file(
            sandbox_id: @sandbox_id,
            path: "#{code_path}/Procfile",
            content: procfile_content
          )
          puts " done"
        end

        def start_postgres
          print "Starting PostgreSQL..."
          exec_sh("sudo service postgresql start")
          exec_sh("sudo -u postgres createuser -s daytona 2>/dev/null || true")
          exec_sh("createdb #{db_name} 2>/dev/null || true")
          puts " done"
        end

        def run_install_commands(&block)
          puts "Running install..."
          @install.each do |item|
            # Support both formats: string or {name:, command:}
            if item.is_a?(Hash)
              name = item["name"] || item[:name]
              cmd = item["command"] || item[:command]
            else
              name = nil
              cmd = item
            end

            puts "  $ #{cmd}"
            block&.call(:install_start, { name:, command: cmd })
            result = exec_sh("cd #{code_path} && #{mise_prefix} POSTGRES_DB=#{db_name} #{cmd}")
            exit_code = result["exitCode"]
            output = result["result"]
            block&.call(:install_complete, { name:, command: cmd, exit_code:, output: })
            if exit_code != 0
              raise InstallError, "Install command failed: #{cmd}\nExit code: #{exit_code}\nOutput: #{output}"
            end
          end
        end

        def start_app
          puts "Starting app..."
          @daytona.create_session(sandbox_id: @sandbox_id, session_id: "app")
          @daytona.session_execute(
            sandbox_id: @sandbox_id,
            session_id: "app",
            command: "cd #{code_path} && #{mise_prefix} POSTGRES_DB=#{db_name} PORT=3000 overmind start"
          )
        end

        def start_tunnel
          return unless @tunnel_token

          puts "Starting tunnel..."

          # Write token to file (avoid shell escaping issues)
          @daytona.upload_file(
            sandbox_id: @sandbox_id,
            path: "/tmp/tunnel-token",
            content: @tunnel_token
          )

          @daytona.create_session(sandbox_id: @sandbox_id, session_id: "tunnel")
          @daytona.session_execute(
            sandbox_id: @sandbox_id,
            session_id: "tunnel",
            command: "cloudflared tunnel run --protocol http2 --token-file /tmp/tunnel-token"
          )
        end

        # Deploy Cloudflare Worker for auth in front of tunnel
        # Worker validates access_token and sets HttpOnly cookie, then passes through to tunnel
        # Optionally injects HTML into responses (for console, etc.)
        def deploy_worker
          return unless @cloudflare

          print "Securing session..."

          worker_name = "kml-#{@service_name}-#{@slug}"
          hostname = "#{@slug}.#{@cloudflare.domain}"

          @cloudflare.deploy_worker(
            worker_name:,
            access_token: @access_token,
            hostname:,
            files: @worker_files,
            bindings: @worker_bindings,
            injection: @worker_injection
          )
          puts " done"
        end

        def ssh_to_https(url)
          if url =~ /^git@([^:]+):(.+)$/
            "https://#{$1}/#{$2}"
          else
            url
          end
        end

        # Parse overmind status output
        # Input: "web   | running\ncss   | running\n"
        # Output: [{ name: "web", status: "running" }, { name: "css", status: "running" }]
        def parse_overmind_status(output)
          output.split("\n").filter_map do |line|
            next if line.strip.empty?

            parts = line.split("|").map(&:strip)
            next unless parts.length == 2

            { name: parts[0], status: parts[1] }
          end
        end
    end
  end
end
