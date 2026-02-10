# frozen_string_literal: true

require "shellwords"

module Kml
  class Sandbox
    def initialize(hetzner:, config:)
      @hetzner = hetzner
      @config = config
      @server_name = "#{config.service_name}-sandbox"
    end

    def service_name
      @config.service_name
    end

    def code_path
      @config.code_path
    end

    def server_ip
      server = @hetzner.find_server(@server_name)
      raise Error, "No sandbox server found" unless server

      @hetzner.server_ip(server)
    end

    def remote_exec(cmd)
      ip = server_ip
      `ssh -o StrictHostKeyChecking=no deploy@#{ip} #{Shellwords.escape(cmd)}`
    end

    def anthropic_env_vars
      api_key = ENV["ANTHROPIC_AUTH_TOKEN"] || load_env_var("ANTHROPIC_AUTH_TOKEN") ||
                ENV["ANTHROPIC_API_KEY"] || load_env_var("ANTHROPIC_API_KEY")
      raise Error, "ANTHROPIC_AUTH_TOKEN not set. Run 'kml init' first." unless api_key

      base_url = ENV["ANTHROPIC_BASE_URL"] || load_env_var("ANTHROPIC_BASE_URL")

      env_vars = "ANTHROPIC_API_KEY=#{Shellwords.escape(api_key)}"
      env_vars += " ANTHROPIC_BASE_URL=#{Shellwords.escape(base_url)}" if base_url
      env_vars
    end

    def deploy
      print "[1/5] Provision server..."
      @ip = provision_or_find_server

      step(2, "Generate sandbox config", steps: 5) do
        @config.generate_sandbox(ip: @ip)
        @config.write_sandbox_config
        @config.write_sandbox_secrets
      end
      step(3, "Sync code", steps: 5) { sync_code(@ip) }

      if sandbox_running?(@ip)
        puts "[4/5] App already running ✓"
      else
        step(4, "Kamal setup", steps: 5) { run_kamal_setup }
      end

      step(5, "Setup tunnel", steps: 5) { setup_tunnel(@ip) }

      puts "\n✓ Sandbox ready at #{@ip}"
      @ip
    end

    def destroy
      # Delete tunnel first
      if (cf = cloudflare)
        tunnel = cf.find_tunnel(tunnel_name)
        if tunnel
          puts "Deleting tunnel..."
          cf.delete_tunnel(tunnel[:id])
        end
      end

      server = @hetzner.find_server(@server_name)
      if server
        puts "Deleting server #{server['id']}..."
        @hetzner.delete_server(server["id"])
        puts "✓ Done"
      else
        puts "No server found."
      end
    end

    def tunnel_name
      "kml-#{@config.service_name}-sandbox"
    end

    def tunnel_id
      return @tunnel_id if defined?(@tunnel_id)

      cf = cloudflare
      return nil unless cf

      tunnel = cf.find_tunnel(tunnel_name)
      @tunnel_id = tunnel&.dig(:id)
    end

    def cloudflare
      return @cloudflare if defined?(@cloudflare)

      api_token = ENV["CLOUDFLARE_API_TOKEN"] || load_env_var("CLOUDFLARE_API_TOKEN")
      account_id = ENV["CLOUDFLARE_ACCOUNT_ID"] || load_env_var("CLOUDFLARE_ACCOUNT_ID")
      zone_id = ENV["CLOUDFLARE_ZONE_ID"] || load_env_var("CLOUDFLARE_ZONE_ID")
      domain = ENV["CLOUDFLARE_DOMAIN"] || load_env_var("CLOUDFLARE_DOMAIN")

      return nil unless api_token && account_id && zone_id && domain

      @cloudflare = Cloudflare.new(
        api_token: api_token,
        account_id: account_id,
        zone_id: zone_id,
        domain: domain
      )
    end

    def exec(command)
      system("kamal", "app", "exec", "-d", "sandbox", "--reuse", command)
    end

    def ssh
      server = @hetzner.find_server(@server_name)
      raise Error, "No sandbox server found" unless server

      ip = @hetzner.server_ip(server)
      Kernel.exec("ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}")
    end

    def claude(prompt)
      server = @hetzner.find_server(@server_name)
      raise Error, "No sandbox server found" unless server

      ip = @hetzner.server_ip(server)

      # Support both new (AUTH_TOKEN) and old (API_KEY) env var names
      api_key = ENV["ANTHROPIC_AUTH_TOKEN"] || load_env_var("ANTHROPIC_AUTH_TOKEN") ||
                ENV["ANTHROPIC_API_KEY"] || load_env_var("ANTHROPIC_API_KEY")
      raise Error, "ANTHROPIC_AUTH_TOKEN not set. Run 'kml init' first." unless api_key

      base_url = ENV["ANTHROPIC_BASE_URL"] || load_env_var("ANTHROPIC_BASE_URL")

      code_path = @config.code_path
      env_vars = "ANTHROPIC_API_KEY=#{Shellwords.escape(api_key)}"
      env_vars += " ANTHROPIC_BASE_URL=#{Shellwords.escape(base_url)}" if base_url

      cmd = "cd #{code_path} && #{env_vars} claude -p --dangerously-skip-permissions #{Shellwords.escape(prompt)}"

      Kernel.exec("ssh", "-tt", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}", cmd)
    end

    private

    def load_env_var(name)
      return unless File.exist?(".env")
      File.read(".env")[/#{name}=(.+)/, 1]&.strip
    end

    def github_token
      # 1. gh CLI (most common)
      token = `gh auth token 2>/dev/null`.strip
      return token unless token.empty?

      # 2. Environment variable
      token = ENV["GITHUB_TOKEN"] || ENV["GH_TOKEN"]
      return token if token && !token.empty?

      # 3. .env file
      token = load_env_var("GITHUB_TOKEN") || load_env_var("GH_TOKEN")
      return token if token && !token.empty?

      # 4. git credential helper
      token = `echo "protocol=https\nhost=github.com" | git credential fill 2>/dev/null | grep password | cut -d= -f2`.strip
      return token unless token.empty?

      nil
    end

    def git_user_name
      name = `git config user.name 2>/dev/null`.strip
      name.empty? ? "kml-sandbox" : name
    end

    def git_user_email
      email = `git config user.email 2>/dev/null`.strip
      email.empty? ? "sandbox@kml.dev" : email
    end

    def setup_ssh_key(ip)
      # Find local SSH key
      key_paths = %w[~/.ssh/id_ed25519 ~/.ssh/id_rsa].map { |p| File.expand_path(p) }
      private_key = key_paths.find { |p| File.exist?(p) }
      return unless private_key

      # Copy to server
      system(
        "scp", "-o", "StrictHostKeyChecking=no",
        private_key, "deploy@#{ip}:~/.ssh/",
        out: File::NULL, err: File::NULL
      )

      key_name = File.basename(private_key)
      system(
        "ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
        "chmod 600 ~/.ssh/#{key_name} && ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null",
        out: File::NULL, err: File::NULL
      )
    end

    def step(num, name, show_done: true, steps: 5)
      print "[#{num}/#{steps}] #{name}..."
      $stdout.flush
      result = yield
      puts " ✓" if show_done
      result
    end

    def provision_or_find_server
      server = @hetzner.find_server(@server_name)

      if server
        ip = @hetzner.server_ip(server)
        puts " exists (#{ip})"
        clear_known_host(ip)
        return ip
      end

      puts ""
      user_data = @hetzner.cloud_init_script(@config.ssh_public_key)

      print "    Creating server..."
      server = @hetzner.create_server(
        name: @server_name,
        user_data: user_data
      )
      server = wait_for_server(server["id"])
      ip = @hetzner.server_ip(server)
      puts " #{ip}"

      clear_known_host(ip)

      print "    Waiting for SSH..."
      wait_for_ssh(ip)
      puts " ok"

      print "    Waiting for Docker..."
      wait_for_docker(ip)
      puts " ok"

      ip
    end

    def wait_for_server(id)
      loop do
        server = @hetzner.get_server(id)
        return server if server && server["status"] == "running"
        sleep 3
      end
    end

    def clear_known_host(ip)
      system("ssh-keygen", "-R", ip, out: File::NULL, err: File::NULL)
    end

    def wait_for_ssh(ip)
      loop do
        result = system(
          "ssh", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no",
          "deploy@#{ip}", "true",
          out: File::NULL, err: File::NULL
        )
        break if result
        sleep 5
      end
    end

    def wait_for_docker(ip)
      puts ""
      # Stream cloud-init with forced line buffering via stdbuf, kill when docker ready
      system(
        "ssh", "-tt", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
        "sudo stdbuf -oL tail -f /var/log/cloud-init-output.log | " \
        "stdbuf -oL sed 's/^/    /' & " \
        "PID=$!; while ! docker version >/dev/null 2>&1; do sleep 2; done; kill $PID 2>/dev/null; echo '    Docker ready'"
      )
    end


    def sync_code(ip)
      code_path = @config.code_path

      unless system(
        "ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
        "sudo mkdir -p #{code_path} && sudo chown deploy:deploy #{code_path}",
        out: File::NULL
      )
        raise Error, "Failed to create code directory"
      end

      # Sync including .git for gitops
      unless system(
        "rsync", "-az",
        "--exclude=tmp", "--exclude=log", "--exclude=node_modules",
        "./", "deploy@#{ip}:#{code_path}/"
      )
        raise Error, "Failed to sync code"
      end

      # Setup git auth - always copy SSH key, also try gh auth if token available
      setup_ssh_key(ip)

      if (token = github_token)
        system(
          "ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
          "echo #{Shellwords.escape(token)} | gh auth login --with-token 2>/dev/null || true",
          out: File::NULL, err: File::NULL
        )
      end

      # Configure git user
      system(
        "ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
        "git config --global user.name '#{git_user_name}' && git config --global user.email '#{git_user_email}'",
        out: File::NULL
      )
    end

    def run_kamal_setup
      puts "" # newline before kamal output
      # Release any stale lock first
      system("kamal", "lock", "release", "-d", "sandbox", out: File::NULL, err: File::NULL)
      unless system("kamal", "setup", "-d", "sandbox")
        raise Error, "Kamal setup failed"
      end
    end

    def setup_tunnel(ip)
      cf = cloudflare
      return unless cf

      # Create or find tunnel
      tunnel = cf.find_or_create_tunnel(tunnel_name)
      token = cf.get_tunnel_token(tunnel[:id])

      # Initialize tunnel config with catch-all
      cf.put_tunnel_config(tunnel[:id], [{ "service" => "http_status:404" }])

      # Run cloudflared in Docker
      system(
        "ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
        "docker rm -f cloudflared 2>/dev/null; " \
        "docker run -d --name cloudflared --network host --restart unless-stopped " \
        "cloudflare/cloudflared:latest tunnel --no-autoupdate run --token #{token}",
        out: File::NULL
      )
    end

    def sandbox_running?(ip)
      # Check if sandbox container is running
      output = `ssh -o StrictHostKeyChecking=no deploy@#{ip} "docker ps --filter name=#{@config.service_name}-sandbox-web -q" 2>/dev/null`.strip
      !output.empty?
    end
  end
end
