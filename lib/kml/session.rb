# frozen_string_literal: true

require "shellwords"
require "securerandom"

module Kml
  class Session
    attr_reader :slug, :uuid, :branch, :port, :database, :created_at

    def initialize(slug:, uuid: nil, branch: nil, port: nil, database: nil, created_at: nil, sandbox:)
      @slug = slug
      @uuid = uuid
      @branch = branch || "kml/#{slug}"
      @port = port
      @database = database || "app_session_#{slug.tr('-', '_')}"
      @created_at = created_at
      @sandbox = sandbox
    end

    def tmux_name
      "kml-#{slug}"
    end

    def container_name
      "kml-#{slug}-app"
    end

    def worktree_path
      "/home/deploy/sessions/#{slug}"
    end

    def main_code_path
      @sandbox.code_path
    end

    def postgres_container
      @sandbox.db_container_name
    end

    def docker_image
      @sandbox.image_name
    end

    def docker_network
      Sandbox::NETWORK
    end

    def running?
      output = @sandbox.remote_exec("tmux has-session -t #{tmux_name} 2>&1 && echo 'running' || echo 'stopped'")
      output.strip == "running"
    end

    def start!(prompt: nil, detached: false, print_mode: false, json_mode: false)
      # Validate: print/json/detached modes require a prompt
      if (print_mode || json_mode || detached) && prompt.nil?
        raise Error, "Prompt required for -p/-j/-d modes"
      end

      # 1. Create sessions directory and worktree on server
      @sandbox.remote_exec(<<~SH)
        mkdir -p /home/deploy/sessions
        cd #{main_code_path}
        git worktree add #{worktree_path} -b #{branch} 2>/dev/null || \
        git worktree add #{worktree_path} #{branch} 2>/dev/null || true
      SH

      # 2. Create database for session
      @sandbox.remote_exec(<<~SH)
        docker exec #{postgres_container} createdb -U app #{database} 2>/dev/null || true
      SH

      # 3. Start app container
      @sandbox.remote_exec(<<~SH)
        docker rm -f #{container_name} 2>/dev/null || true
        docker run -d \
          --name #{container_name} \
          --network #{docker_network} \
          -v #{worktree_path}:/rails \
          -p #{port}:3000 \
          -e RAILS_ENV=development \
          -e RAILS_LOG_TO_STDOUT=1 \
          -e POSTGRES_HOST=#{postgres_container} \
          -e POSTGRES_DB=#{database} \
          -e POSTGRES_USER=app \
          -e POSTGRES_PASSWORD=sandbox123 \
          #{docker_image} \
          bash -c "bin/rails db:prepare && bin/rails assets:precompile && bin/rails s -b 0.0.0.0"
      SH

      # 4. Setup tunnel ingress
      @public_url = setup_tunnel_ingress

      # 5. Create tmux session with 2 windows
      @sandbox.remote_exec(<<~SH)
        tmux kill-session -t #{tmux_name} 2>/dev/null || true
        tmux new-session -d -s #{tmux_name} -n app
        tmux send-keys -t #{tmux_name}:app "docker logs -f #{container_name}" Enter
        tmux new-window -t #{tmux_name} -n claude
      SH

      # 6. Start Claude in tmux
      claude_cmd = build_claude_cmd(
        prompt: prompt,
        new_session: true,
        print_mode: print_mode || detached,
        json_mode: json_mode
      )
      @sandbox.remote_exec("tmux send-keys -t #{tmux_name}:claude #{Shellwords.escape(claude_cmd)} Enter")

      # 7. Attach or print message
      if detached
        puts "Session '#{slug}' started in background."
        puts "URL: https://#{@public_url}" if @public_url
        puts "Use 'kml session continue #{slug}' to attach."
      else
        attach!
      end
    end

    def continue!(prompt: nil, detached: false)
      ensure_app_running!

      if prompt
        claude_cmd = build_claude_cmd(prompt: prompt, new_session: false, print_mode: true)
        @sandbox.remote_exec("tmux send-keys -t #{tmux_name}:claude #{Shellwords.escape(claude_cmd)} Enter")
      end

      attach! unless detached
    end

    def attach!
      ip = @sandbox.server_ip
      Kernel.exec("ssh", "-t", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}", "tmux attach -t #{tmux_name}")
    end

    def stop!
      @sandbox.remote_exec("tmux kill-session -t #{tmux_name} 2>/dev/null || true")
      @sandbox.remote_exec("docker stop #{container_name} 2>/dev/null || true")
      @sandbox.remote_exec("docker rm #{container_name} 2>/dev/null || true")
    end

    def delete!
      stop!
      # Remove tunnel ingress
      remove_tunnel_ingress
      # Remove worktree
      @sandbox.remote_exec("cd #{main_code_path} && git worktree remove #{worktree_path} --force 2>/dev/null || true")
      @sandbox.remote_exec("rm -rf #{worktree_path}")
      # Drop database
      @sandbox.remote_exec("docker exec #{postgres_container} dropdb -U app #{database} 2>/dev/null || true")
      # Remove from local storage
      SessionStore.delete(slug)
    end

    def public_url
      cf = @sandbox.cloudflare
      return nil unless cf
      "sandbox-#{slug}.#{cf.domain}"
    end

    def build_claude_cmd(prompt: nil, new_session: true, print_mode: false, json_mode: false)
      env = @sandbox.anthropic_env_vars
      session_flag = new_session ? "--session-id #{uuid}" : "--resume #{uuid}"

      cmd = "cd #{worktree_path} && #{env} claude #{session_flag} --verbose --dangerously-skip-permissions"
      cmd += " -p" if print_mode || json_mode
      cmd += " --output-format=stream-json" if json_mode
      cmd += " #{Shellwords.escape(prompt)}" if prompt
      cmd
    end

    private

    def ensure_app_running!
      # Check if container is running, restart if not
      output = @sandbox.remote_exec("docker ps -q --filter name=#{container_name}")
      return unless output.strip.empty?

      puts "Restarting app container..."
      @sandbox.remote_exec(<<~SH)
        docker rm -f #{container_name} 2>/dev/null || true
        docker run -d \
          --name #{container_name} \
          --network #{docker_network} \
          -v #{worktree_path}:/rails \
          -p #{port}:3000 \
          -e RAILS_ENV=development \
          -e RAILS_LOG_TO_STDOUT=1 \
          -e POSTGRES_HOST=#{postgres_container} \
          -e POSTGRES_DB=#{database} \
          -e POSTGRES_USER=app \
          -e POSTGRES_PASSWORD=sandbox123 \
          #{docker_image} \
          bash -c "bin/rails db:prepare && bin/rails assets:precompile && bin/rails s -b 0.0.0.0"
      SH

      # Also ensure tmux session exists
      unless running?
        @sandbox.remote_exec(<<~SH)
          tmux new-session -d -s #{tmux_name} -n app
          tmux send-keys -t #{tmux_name}:app "docker logs -f #{container_name}" Enter
          tmux new-window -t #{tmux_name} -n claude
        SH
      end
    end

    def setup_tunnel_ingress
      cf = @sandbox.cloudflare
      tunnel_id = @sandbox.tunnel_id
      return nil unless cf && tunnel_id

      cf.add_session_ingress(tunnel_id, slug, port)
    end

    def remove_tunnel_ingress
      cf = @sandbox.cloudflare
      tunnel_id = @sandbox.tunnel_id
      return unless cf && tunnel_id

      cf.remove_session_ingress(tunnel_id, slug)
    end
  end
end
