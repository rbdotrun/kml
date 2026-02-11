# frozen_string_literal: true

require "shellwords"
require "securerandom"

module Kml
  class Session
    attr_reader :slug, :uuid, :sandbox_id, :access_token, :created_at

    def initialize(slug:, uuid: nil, sandbox_id: nil, access_token: nil, created_at: nil, sandbox:, daytona:)
      @slug = slug
      @uuid = uuid
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

    def public_url_with_token
      url = public_url
      return nil unless url && access_token

      "#{url}?token=#{access_token}"
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

    def start!(prompt: nil, detached: false, print_mode: false, json_mode: false)
      if (detached || print_mode || json_mode) && prompt.nil?
        raise Error, "Prompt required for detached/print/json mode"
      end

      puts "Creating Daytona sandbox..."

      # Create sandbox from snapshot
      sandbox_result = @daytona.create_sandbox(
        snapshot: @sandbox.snapshot_name,
        name: "kml-#{@sandbox.service_name}-#{slug}",
        auto_stop_interval: 0,  # Don't auto-stop
        public: false
      )

      @sandbox_id = sandbox_result["id"]

      # Update session store with sandbox_id
      SessionStore.update(slug, sandbox_id: @sandbox_id)

      # Wait for sandbox to be ready
      print "Waiting for sandbox..."
      @daytona.wait_for_sandbox(@sandbox_id)
      puts " ready"

      # Clone the repo
      print "Cloning repository..."
      repo_url = config.send(:load_env_var, "GIT_REPO_URL") || git_remote_url
      if repo_url
        @daytona.git_clone(
          sandbox_id: @sandbox_id,
          url: repo_url,
          path: code_path
        )
        puts " done"
      else
        # Upload current directory via rsync-like approach
        puts " (using local files)"
        upload_local_code
      end

      # Get preview URL and token
      preview = @daytona.get_preview_url(sandbox_id: @sandbox_id, port: 3000)
      daytona_preview_url = preview["url"]
      daytona_preview_token = preview["token"]

      # Deploy Cloudflare worker for auth
      print "Setting up auth..."
      @sandbox.deploy_session_worker(slug, access_token, daytona_preview_url, daytona_preview_token)
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

      # Install dependencies and setup
      puts "Running install..."
      config.install.each do |cmd|
        puts "  $ #{cmd}"
        exec_sh("cd #{code_path} && #{mise_prefix} #{cmd}")
      end

      # Start tmux with overmind and claude
      puts "Starting processes..."

      # Create tmux session with app and claude windows
      exec_sh(<<~SH)
        tmux new-session -d -s kml -n app
        tmux send-keys -t kml:app 'cd #{code_path} && #{mise_prefix} PORT=3000 overmind start' Enter
        tmux new-window -t kml -n claude
      SH

      # Start Claude in the claude window
      claude_command = build_claude_cmd(prompt, new_session: true, print_mode: print_mode || detached, json_mode: json_mode)
      exec_sh("tmux send-keys -t kml:claude #{Shellwords.escape(claude_command)} Enter")

      puts ""
      puts "Session '#{slug}' started"
      puts "URL: #{public_url_with_token}"

      if detached
        puts "Use 'kml session continue #{slug}' to attach."
      else
        attach!
      end
    end

    def continue!(prompt: nil, detached: false, json_mode: false)
      # Ensure sandbox is running
      unless running?
        print "Starting sandbox..."
        @daytona.start_sandbox(sandbox_id)
        @daytona.wait_for_sandbox(sandbox_id)
        puts " ready"
      end

      if prompt
        cmd = build_claude_cmd(prompt, print_mode: detached, json_mode: json_mode)
        exec_sh("tmux send-keys -t kml:claude #{Shellwords.escape(cmd)} Enter")
      end

      attach! unless detached
    end

    def attach!
      # Get SSH access info
      ssh_info = @daytona.get_sandbox(sandbox_id)

      # Use Daytona's SSH access
      # For now, we'll use the toolbox to create an interactive session
      puts "Attaching to session..."
      puts "(Use Ctrl+B D to detach from tmux)"

      # Execute tmux attach in the sandbox
      # This requires an interactive PTY which the REST API doesn't support well
      # So we'll use SSH if available, or provide instructions

      ssh_url = ssh_info.dig("sshAccess", "sshUrl")
      if ssh_url
        # Parse ssh://user@host:port format
        match = ssh_url.match(%r{ssh://([^@]+)@([^:]+):(\d+)})
        if match
          user, host, port = match.captures
          Kernel.exec("ssh", "-t", "-p", port, "#{user}@#{host}", "tmux attach -t kml")
        end
      end

      # Fallback: show instructions
      puts ""
      puts "To attach manually, use the Daytona dashboard or CLI:"
      puts "  daytona ssh #{sandbox_id}"
      puts "  tmux attach -t kml"
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

      # Delete sandbox
      if sandbox_id
        begin
          @daytona.delete_sandbox(sandbox_id)
        rescue => e
          # Ignore errors
        end
      end

      # Delete worker and route
      @sandbox.delete_session_worker(slug)

      # Remove from store
      SessionStore.delete(slug)
    end

    private

    def exec_sh(cmd)
      # Use sh -c wrapper for shell operators
      @daytona.execute_command(
        sandbox_id: @sandbox_id,
        command: "sh -c #{Shellwords.escape(cmd)}",
        timeout: 300
      )
    end

    def mise_prefix
      'export PATH="$HOME/.local/bin:$PATH" && eval "$(mise activate bash)" &&'
    end

    def claude_env
      env = []
      env << "ANTHROPIC_AUTH_TOKEN=#{config.send(:load_env_var, 'ANTHROPIC_AUTH_TOKEN')}" if config.send(:load_env_var, 'ANTHROPIC_AUTH_TOKEN')
      env << "ANTHROPIC_BASE_URL=#{config.send(:load_env_var, 'ANTHROPIC_BASE_URL')}" if config.send(:load_env_var, 'ANTHROPIC_BASE_URL')
      env.join(" ")
    end

    def build_claude_cmd(prompt, new_session: false, print_mode: false, json_mode: false)
      session_flag = new_session ? "--session-id #{uuid}" : "--resume #{uuid}"
      cmd = "#{mise_prefix} cd #{code_path} && #{claude_env} claude #{session_flag} --dangerously-skip-permissions"
      if print_mode || json_mode || prompt
        cmd += " -p"
        cmd += " --verbose --output-format=stream-json" if json_mode
        cmd += " #{Shellwords.escape(prompt)}" if prompt
      end
      cmd
    end

    def git_remote_url
      `git remote get-url origin 2>/dev/null`.strip.presence
    end

    def upload_local_code
      # For now, skip - would need to implement file upload
      # In practice, we'd use git clone from a remote
      puts "Warning: Local code upload not yet implemented. Use GIT_REPO_URL."
    end
  end
end
