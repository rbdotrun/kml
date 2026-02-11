# frozen_string_literal: true

require "shellwords"
require "securerandom"

module Kml
  class Session
    attr_reader :slug, :uuid, :port, :branch, :database, :created_at

    def initialize(slug:, uuid: nil, port: nil, branch: nil, database: nil, created_at: nil, sandbox:)
      @slug = slug
      @uuid = uuid
      @port = port
      @branch = branch
      @database = database
      @created_at = created_at
      @sandbox = sandbox
    end

    def public_url
      domain = @sandbox.instance_variable_get(:@config).send(:load_env_var, "CLOUDFLARE_DOMAIN")
      return nil unless domain

      "https://#{slug}.#{domain}"
    end

    def worktree_path
      "/home/deploy/sessions/#{slug}"
    end

    def tmux_name
      "kml-#{slug}"
    end

    def running?
      output = @sandbox.remote_exec_output("tmux has-session -t #{tmux_name} 2>&1 && echo 'running' || echo 'stopped'")
      output == "running"
    end

    def start!(prompt: nil, detached: false, print_mode: false, json_mode: false)
      if (detached || print_mode || json_mode) && prompt.nil?
        raise Error, "Prompt required for detached/print/json mode"
      end

      # Create worktree
      @sandbox.remote_exec(<<~SH)
        mkdir -p /home/deploy/sessions
        cd #{@sandbox.code_path}
        git worktree add #{worktree_path} -b kml/#{slug} 2>/dev/null || \
        git worktree add #{worktree_path} kml/#{slug} 2>/dev/null || true
      SH

      # Write Procfile
      config = @sandbox.instance_variable_get(:@config)
      procfile_content = config.processes.map { |name, cmd| "#{name}: #{cmd}" }.join("\n")
      File.write("/tmp/Procfile.session", procfile_content)
      system("scp", "-o", "StrictHostKeyChecking=no", "/tmp/Procfile.session",
        "deploy@#{@sandbox.server_ip}:#{worktree_path}/Procfile", out: File::NULL)

      # Add tunnel route for this session
      @sandbox.update_tunnel_with_sessions

      # Run db:prepare for the session
      @sandbox.remote_exec("cd #{worktree_path} && bin/rails db:prepare")

      # Create tmux session
      @sandbox.remote_exec(<<~SH)
        tmux kill-session -t #{tmux_name} 2>/dev/null || true
        tmux new-session -d -s #{tmux_name} -n app
        tmux send-keys -t #{tmux_name}:app "cd #{worktree_path} && PORT=#{port} overmind start" Enter
        tmux new-window -t #{tmux_name} -n claude
      SH

      # Start Claude
      cmd = claude_cmd(prompt, new_session: true, print_mode: print_mode, json_mode: json_mode)
      @sandbox.remote_exec("tmux send-keys -t #{tmux_name}:claude #{Shellwords.escape(cmd)} Enter")

      puts "Session '#{slug}' started at #{public_url}"

      if detached
        puts "Use 'kml session continue #{slug}' to attach."
      else
        attach!
      end
    end

    def continue!(prompt: nil, detached: false, json_mode: false)
      if prompt
        cmd = claude_cmd(prompt, print_mode: detached, json_mode: json_mode)
        @sandbox.remote_exec("tmux send-keys -t #{tmux_name}:claude #{Shellwords.escape(cmd)} Enter")
      end

      attach! unless detached
    end

    def attach!
      ip = @sandbox.server_ip
      Kernel.exec("ssh", "-t", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}", "tmux attach -t #{tmux_name}")
    end

    def stop!
      @sandbox.remote_exec("tmux kill-session -t #{tmux_name} 2>/dev/null || true")
    end

    def delete!
      stop!
      @sandbox.remote_exec("cd #{@sandbox.code_path} && git worktree remove #{worktree_path} --force 2>/dev/null || true")
      @sandbox.remote_exec("rm -rf #{worktree_path}")
      SessionStore.delete(slug)
      # Update tunnel to remove this session's route
      @sandbox.update_tunnel_with_sessions
    end

    def claude_env
      config = @sandbox.instance_variable_get(:@config)
      env = []
      env << "ANTHROPIC_AUTH_TOKEN=#{config.send(:load_env_var, 'ANTHROPIC_AUTH_TOKEN')}" if config.send(:load_env_var, 'ANTHROPIC_AUTH_TOKEN')
      env << "ANTHROPIC_BASE_URL=#{config.send(:load_env_var, 'ANTHROPIC_BASE_URL')}" if config.send(:load_env_var, 'ANTHROPIC_BASE_URL')
      env.join(" ")
    end

    def claude_cmd(prompt, new_session: false, print_mode: false, json_mode: false)
      session_flag = new_session ? "--session-id #{uuid}" : "--resume #{uuid}"
      cmd = "cd #{worktree_path} && #{claude_env} claude #{session_flag} --dangerously-skip-permissions"
      if print_mode || json_mode || prompt
        cmd += " -p"
        cmd += " --verbose --output-format=stream-json" if json_mode
        cmd += " #{Shellwords.escape(prompt)}" if prompt
      end
      cmd
    end
  end
end
