# frozen_string_literal: true

require "shellwords"
require "securerandom"

module Kml
  class Session
    attr_reader :slug, :sandbox_id, :access_token, :created_at

    def initialize(slug:, sandbox_id: nil, access_token: nil, created_at: nil, sandbox:, daytona:)
      @slug = slug
      @sandbox_id = sandbox_id
      @access_token = access_token
      @created_at = created_at
      @sandbox = sandbox
      @daytona = daytona
    end

    def public_url
      domain = config.send(:load_env_var, "CLOUDFLARE_DOMAIN")
      return nil unless domain

      "https://#{slug}.#{domain}"
    end

    def config
      @sandbox.instance_variable_get(:@config)
    end

    def code_path
      @sandbox.code_path
    end

    def running?
      return false unless sandbox_id

      begin
        sandbox = @daytona.get_sandbox(sandbox_id)
        %w[started running].include?(sandbox["state"])
      rescue
        false
      end
    end

    # Create sandbox only (no Claude)
    def start!
      sandbox_name = "kml-#{@sandbox.service_name}-#{slug}"

      existing = @daytona.find_sandbox_by_name(sandbox_name)
      if existing
        print "Found existing sandbox, deleting..."
        begin
          @daytona.delete_sandbox(existing["id"])
          sleep 2
        rescue
        end
        puts " done"
      end

      puts "Creating Daytona sandbox..."

      sandbox_result = @daytona.create_sandbox(
        snapshot: @sandbox.snapshot_name,
        name: sandbox_name,
        auto_stop_interval: 0,
        public: false
      )

      @sandbox_id = sandbox_result["id"]
      SessionStore.update(slug, sandbox_id: @sandbox_id)

      print "Waiting for sandbox..."
      @daytona.wait_for_sandbox(@sandbox_id)
      puts " ready"

      # Clone repo
      print "Cloning repository..."
      repo_url = config.send(:load_env_var, "GIT_REPO_URL") || git_remote_url
      if repo_url
        repo_url = ssh_to_https(repo_url)
        github_token = config.send(:load_env_var, "GITHUB_TOKEN")

        @daytona.git_clone(
          sandbox_id: @sandbox_id,
          url: repo_url,
          path: code_path,
          username: github_token ? "x-access-token" : nil,
          password: github_token
        )
        puts " done"
      else
        puts " (no repo)"
      end

      # Setup tunnel
      print "Setting up tunnel..."
      setup_cloudflared_tunnel
      puts " done"

      # Write Procfile
      print "Configuring processes..."
      procfile_content = config.processes.map { |name, cmd| "#{name}: #{cmd}" }.join("\n")
      @daytona.upload_file(
        sandbox_id: @sandbox_id,
        path: "#{code_path}/Procfile",
        content: procfile_content
      )
      puts " done"

      # Start PostgreSQL
      print "Starting PostgreSQL..."
      exec_sh("sudo service postgresql start")
      exec_sh("sudo -u postgres createuser -s daytona 2>/dev/null || true")
      exec_sh("createdb #{db_name} 2>/dev/null || true")
      puts " done"

      # Install dependencies
      puts "Running install..."
      config.install.each do |cmd|
        puts "  $ #{cmd}"
        result = exec_sh("cd #{code_path} && POSTGRES_DB=#{db_name} #{mise_prefix} #{cmd}")
        if result["exitCode"] != 0
          puts "    ERROR (exit #{result['exitCode']}): #{result['result']}"
        end
      end

      # Start app
      puts "Starting app..."
      @daytona.create_session(sandbox_id: @sandbox_id, session_id: "app")
      @daytona.session_execute(
        sandbox_id: @sandbox_id,
        session_id: "app",
        command: "cd #{code_path} && #{mise_prefix} POSTGRES_DB=#{db_name} PORT=3000 overmind start"
      )

      # Start tunnel
      puts "Starting tunnel..."
      if config.tunnel_id
        @daytona.create_session(sandbox_id: @sandbox_id, session_id: "tunnel")
        @daytona.session_execute(
          sandbox_id: @sandbox_id,
          session_id: "tunnel",
          command: "cloudflared tunnel --config /home/daytona/.cloudflared/config.yml --protocol http2 run"
        )
      end

      puts ""
      puts "Session '#{slug}' ready"
      puts "URL: #{public_url}"
      puts ""
      puts "Run: kml session prompt #{slug} \"your prompt\""
    end

    # Run Claude (new conversation or resume)
    def run!(prompt:, resume_uuid: nil)
      raise Error, "Prompt required" if prompt.nil? || prompt.empty?

      unless running?
        raise Error, "Sandbox not running. Run 'kml session new #{slug}' first."
      end

      uuid = resume_uuid || SecureRandom.uuid
      session_flag = resume_uuid ? "--resume #{uuid}" : "--session-id #{uuid}"

      # Track conversation
      if resume_uuid
        SessionStore.update_conversation(slug, uuid: uuid, prompt: prompt)
      else
        SessionStore.add_conversation(slug, uuid: uuid, prompt: prompt)
      end

      script = <<~SH
        #!/bin/bash
        export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
        #{claude_env_export}
        cd #{code_path}
        claude #{session_flag} --dangerously-skip-permissions -p --verbose --output-format=stream-json --include-partial-messages #{Shellwords.escape(prompt)} 2>&1
      SH

      @daytona.upload_file(
        sandbox_id: @sandbox_id,
        path: "/tmp/run_claude.sh",
        content: script
      )

      # Execute sync and print output
      result = @daytona.execute_command(
        sandbox_id: @sandbox_id,
        command: "bash /tmp/run_claude.sh",
        timeout: 600
      )

      puts result["result"]
    end

    def conversations
      SessionStore.conversations(slug)
    end

    def stop!
      return unless sandbox_id

      begin
        @daytona.stop_sandbox(sandbox_id)
        puts "Session '#{slug}' stopped."
      rescue => e
        puts "Warning: #{e.message}"
      end
    end

    def delete!
      stop!

      if sandbox_id
        begin
          @daytona.delete_sandbox(sandbox_id)
        rescue
        end
      end

      @sandbox.delete_session_worker(slug)
      SessionStore.delete(slug)
    end

    private

    def exec_sh(cmd)
      @daytona.execute_command(
        sandbox_id: @sandbox_id,
        command: "bash -c #{cmd.inspect}",
        timeout: 600
      )
    end

    def db_name
      slug.gsub("-", "_") + "_dev"
    end

    def mise_prefix
      'export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH" &&'
    end

    def claude_env_export
      lines = []
      lines << "export ANTHROPIC_AUTH_TOKEN=#{config.send(:load_env_var, 'ANTHROPIC_AUTH_TOKEN')}" if config.send(:load_env_var, 'ANTHROPIC_AUTH_TOKEN')
      lines << "export ANTHROPIC_BASE_URL=#{config.send(:load_env_var, 'ANTHROPIC_BASE_URL')}" if config.send(:load_env_var, 'ANTHROPIC_BASE_URL')
      lines.join("\n")
    end

    def git_remote_url
      url = `git remote get-url origin 2>/dev/null`.strip
      url.empty? ? nil : url
    end

    def ssh_to_https(url)
      if url =~ /^git@([^:]+):(.+)$/
        "https://#{$1}/#{$2}"
      else
        url
      end
    end

    def setup_cloudflared_tunnel
      domain = config.send(:load_env_var, "CLOUDFLARE_DOMAIN")
      tunnel_id = config.tunnel_id
      credentials = config.tunnel_credentials

      return unless domain && tunnel_id && credentials

      hostname = "#{slug}.#{domain}"

      @daytona.upload_file(
        sandbox_id: @sandbox_id,
        path: "/home/daytona/.cloudflared/credentials.json",
        content: credentials
      )

      tunnel_config = <<~YAML
        tunnel: #{tunnel_id}
        credentials-file: /home/daytona/.cloudflared/credentials.json
        ingress:
          - hostname: #{hostname}
            service: http://localhost:3000
          - service: http_status:404
      YAML

      @daytona.upload_file(
        sandbox_id: @sandbox_id,
        path: "/home/daytona/.cloudflared/config.yml",
        content: tunnel_config
      )

      @sandbox.ensure_tunnel_dns(slug)
    end
  end
end
