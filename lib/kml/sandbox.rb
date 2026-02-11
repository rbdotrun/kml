# frozen_string_literal: true

require "shellwords"

module Kml
  class Sandbox
    NETWORK = "kml"
    POSTGRES_PASSWORD = "sandbox123"

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

    def remote_exec_stream(cmd)
      ip = server_ip
      system("ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}", cmd)
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

      step(2, "Sync code") { sync_code(@ip) }

      if sandbox_running?(@ip)
        puts "[3/5] App already running ✓"
      else
        step(3, "Build & run containers") { build_and_run(@ip) }
      end

      step(4, "Setup tunnel") { setup_tunnel(@ip) }

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
      remote_exec_stream("docker exec -it #{app_container_name} #{command}")
    end

    def ssh
      server = @hetzner.find_server(@server_name)
      raise Error, "No sandbox server found" unless server

      ip = @hetzner.server_ip(server)
      Kernel.exec("ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}")
    end

    # Container names
    def app_container_name
      "#{service_name}-app"
    end

    def db_container_name
      "#{service_name}-db"
    end

    def image_name
      "#{service_name}:sandbox"
    end

    private

    def load_env_var(name)
      return unless File.exist?(".env")
      File.read(".env")[/#{name}=(.+)/, 1]&.strip
    end

    def github_token
      token = `gh auth token 2>/dev/null`.strip
      return token unless token.empty?

      token = ENV["GITHUB_TOKEN"] || ENV["GH_TOKEN"]
      return token if token && !token.empty?

      token = load_env_var("GITHUB_TOKEN") || load_env_var("GH_TOKEN")
      return token if token && !token.empty?

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
      key_paths = %w[~/.ssh/id_ed25519 ~/.ssh/id_rsa].map { |p| File.expand_path(p) }
      private_key = key_paths.find { |p| File.exist?(p) }
      return unless private_key

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

      unless system(
        "rsync", "-az",
        "--exclude=tmp", "--exclude=log", "--exclude=node_modules",
        "./", "deploy@#{ip}:#{code_path}/"
      )
        raise Error, "Failed to sync code"
      end

      # Create directories needed by Dockerfile
      system(
        "ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
        "cd #{code_path} && mkdir -p log tmp storage",
        out: File::NULL
      )

      setup_ssh_key(ip)

      if (token = github_token)
        system(
          "ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
          "echo #{Shellwords.escape(token)} | gh auth login --with-token 2>/dev/null || true",
          out: File::NULL, err: File::NULL
        )
      end

      system(
        "ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
        "git config --global user.name '#{git_user_name}' && git config --global user.email '#{git_user_email}'",
        out: File::NULL
      )
    end

    def build_and_run(ip)
      puts "" # newline before build output

      # Create network
      system(
        "ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
        "docker network create #{NETWORK} 2>/dev/null || true",
        out: File::NULL
      )

      # Build image on server
      puts "    Building image..."
      unless system(
        "ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
        "cd #{code_path} && docker build -t #{image_name} ."
      )
        raise Error, "Docker build failed"
      end

      # Run postgres
      puts "    Starting postgres..."
      system(
        "ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
        "docker rm -f #{db_container_name} 2>/dev/null || true"
      )
      unless system(
        "ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
        "docker run -d " \
        "--name #{db_container_name} " \
        "--network #{NETWORK} " \
        "--restart unless-stopped " \
        "-e POSTGRES_USER=app " \
        "-e POSTGRES_PASSWORD=#{POSTGRES_PASSWORD} " \
        "-e POSTGRES_DB=app_sandbox " \
        "-v #{service_name}_pgdata:/var/lib/postgresql/data " \
        "postgres:17",
        out: File::NULL
      )
        raise Error, "Failed to start postgres"
      end

      # Wait for postgres
      print "    Waiting for postgres..."
      10.times do
        sleep 1
        result = `ssh -o StrictHostKeyChecking=no deploy@#{ip} "docker exec #{db_container_name} pg_isready -U app 2>/dev/null"`.strip
        if result.include?("accepting connections")
          puts " ok"
          break
        end
        print "."
      end

      # Run app
      puts "    Starting app..."
      system(
        "ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
        "docker rm -f #{app_container_name} 2>/dev/null || true"
      )
      unless system(
        "ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
        "docker run -d " \
        "--name #{app_container_name} " \
        "--network #{NETWORK} " \
        "--restart unless-stopped " \
        "-v #{code_path}:/rails " \
        "-p 3000:3000 " \
        "-e RAILS_ENV=development " \
        "-e RAILS_LOG_TO_STDOUT=1 " \
        "-e POSTGRES_HOST=#{db_container_name} " \
        "-e POSTGRES_USER=app " \
        "-e POSTGRES_PASSWORD=#{POSTGRES_PASSWORD} " \
        "-e POSTGRES_DB=app_sandbox " \
        "#{image_name} " \
        "bash -c 'bin/rails db:prepare && bin/rails s -b 0.0.0.0'",
        out: File::NULL
      )
        raise Error, "Failed to start app"
      end

      # Wait for app to be healthy
      print "    Waiting for app..."
      30.times do
        sleep 2
        result = `ssh -o StrictHostKeyChecking=no deploy@#{ip} "curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/up 2>/dev/null"`.strip
        if result == "200"
          puts " ok"
          return
        end
        print "."
      end
      puts " timeout (app may still be starting)"
    end

    def setup_tunnel(ip)
      cf = cloudflare
      return unless cf

      tunnel = cf.find_or_create_tunnel(tunnel_name)
      token = cf.get_tunnel_token(tunnel[:id])

      cf.put_tunnel_config(tunnel[:id], [{ "service" => "http_status:404" }])

      system(
        "ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
        "docker rm -f cloudflared 2>/dev/null; " \
        "docker run -d --name cloudflared --network host --restart unless-stopped " \
        "cloudflare/cloudflared:latest tunnel --no-autoupdate run --token #{token}",
        out: File::NULL
      )
    end

    def sandbox_running?(ip)
      output = `ssh -o StrictHostKeyChecking=no deploy@#{ip} "docker ps --filter name=#{app_container_name} -q" 2>/dev/null`.strip
      !output.empty?
    end
  end
end
