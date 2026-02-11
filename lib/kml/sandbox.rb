# frozen_string_literal: true

require "shellwords"
require "open3"
require "stringio"
require "faraday"
require "faraday/multipart"

module Kml
  class Sandbox
    AUTH_WORKER_SCRIPT = <<~JS
      function parseCookies(cookieHeader) {
        const cookies = {};
        if (!cookieHeader) return cookies;
        cookieHeader.split(';').forEach(cookie => {
          const [name, ...rest] = cookie.trim().split('=');
          if (name) cookies[name] = rest.join('=');
        });
        return cookies;
      }

      export default {
        async fetch(request, env) {
          const url = new URL(request.url);
          const path = url.pathname;

          // Assets don't need auth - pass through
          if (path.startsWith('/assets/') || path.startsWith('/icon')) {
            return fetch(request);
          }

          const cookies = parseCookies(request.headers.get('Cookie') || '');
          const tokenParam = url.searchParams.get('token');
          const cookieToken = cookies['kml_token'];

          const token = tokenParam || cookieToken;
          if (!token || token !== env.ACCESS_TOKEN) {
            return new Response('Not Found', { status: 404 });
          }

          // First visit with token - set cookie and redirect to clean URL
          if (tokenParam) {
            url.searchParams.delete('token');
            return new Response(null, {
              status: 302,
              headers: {
                'Location': url.toString(),
                'Set-Cookie': `kml_token=${token}; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=86400`,
                'Cache-Control': 'no-store'
              }
            });
          }

          return fetch(request);
        }
      };
    JS

    SETUP_COMMANDS = [
      { name: "Update apt", cmd: "sudo apt-get update" },
      { name: "Configure firewall", cmd: "sudo ufw allow 22/tcp && sudo ufw --force enable" },
      { name: "Install build tools", cmd: "sudo apt-get install -y git rsync build-essential libssl-dev libreadline-dev zlib1g-dev libyaml-dev tmux libpq-dev" },
      { name: "Install postgres", cmd: "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-contrib || sudo dpkg --configure -a" },
      { name: "Create postgres user", cmd: "sudo -u postgres createuser -s deploy 2>/dev/null || true" },
      { name: "Configure postgres auth", cmd: "sudo sed -i 's/peer/trust/g; s/scram-sha-256/trust/g' /etc/postgresql/*/main/pg_hba.conf && sudo systemctl restart postgresql" },
      { name: "Install mise", cmd: "curl -fsSL https://mise.run | sh" },
      { name: "Configure mise", cmd: 'echo "export PATH=\"$HOME/.local/bin:$PATH\"" >> ~/.bashrc && echo "eval \"$($HOME/.local/bin/mise activate bash)\"" >> ~/.bashrc' },
      { name: "Configure mise settings", cmd: "~/.local/bin/mise settings set ruby.compile false" },
      { name: "Install ruby", cmd: "~/.local/bin/mise use -g ruby@3.4" },
      { name: "Install node", cmd: "~/.local/bin/mise use -g node@20" },
      { name: "Install overmind", cmd: "sudo curl -fsSL -L https://github.com/DarthSim/overmind/releases/download/v2.5.1/overmind-v2.5.1-linux-amd64.gz | gunzip | sudo tee /usr/local/bin/overmind > /dev/null && sudo chmod +x /usr/local/bin/overmind" },
      { name: "Install cloudflared", cmd: "sudo curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared && sudo chmod +x /usr/local/bin/cloudflared" },
      { name: "Install claude-code", cmd: "~/.local/bin/mise exec -- npm install -g @anthropic-ai/claude-code" },
    ].freeze

    SNAPSHOT_NAME = "kml-base"

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
      system("ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
        "bash -l -c #{Shellwords.escape(cmd)}", out: File::NULL, err: File::NULL)
    end

    def remote_exec_output(cmd)
      ip = server_ip
      stdout, _, _ = Open3.capture3(
        "ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
        "bash -l -c #{Shellwords.escape(cmd)}"
      )
      stdout.strip
    end

    def remote_exec_stream(cmd)
      ip = server_ip
      system("ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
        "bash -l -c #{Shellwords.escape(cmd)}")
    end

    def add_tunnel_route(hostname, port)
      update_tunnel_with_sessions
    end

    def remove_tunnel_route(hostname)
      update_tunnel_with_sessions
    end

    def deploy_session_worker(slug, access_token)
      account_id = @config.cloudflare_account_id
      api_token = @config.cloudflare_api_token
      return unless account_id && api_token

      worker_name = "kml-#{service_name}-#{slug}"

      conn = Faraday.new(url: "https://api.cloudflare.com/client/v4") do |f|
        f.request :json
        f.response :json
        f.headers["Authorization"] = "Bearer #{api_token}"
      end

      # Upload worker script with metadata
      metadata = {
        main_module: "worker.js",
        bindings: [
          { type: "secret_text", name: "ACCESS_TOKEN", text: access_token }
        ]
      }

      # Use multipart form for worker upload
      conn_multipart = Faraday.new(url: "https://api.cloudflare.com/client/v4") do |f|
        f.request :multipart
        f.response :json
        f.headers["Authorization"] = "Bearer #{api_token}"
      end

      conn_multipart.put("accounts/#{account_id}/workers/scripts/#{worker_name}",
        "worker.js" => Faraday::Multipart::FilePart.new(
          StringIO.new(AUTH_WORKER_SCRIPT),
          "application/javascript+module",
          "worker.js"
        ),
        "metadata" => Faraday::Multipart::FilePart.new(
          StringIO.new(JSON.generate(metadata)),
          "application/json",
          "metadata.json"
        )
      )

      # Create route for this session's hostname
      zone_id = @config.cloudflare_zone_id
      domain = @config.send(:load_env_var, "CLOUDFLARE_DOMAIN")
      return unless zone_id && domain

      hostname = "#{slug}.#{domain}"
      pattern = "#{hostname}/*"

      # Check if route exists
      response = conn.get("zones/#{zone_id}/workers/routes")
      routes = response.body.dig("result") || []
      existing = routes.find { |r| r["pattern"] == pattern }

      if existing
        conn.put("zones/#{zone_id}/workers/routes/#{existing['id']}", {
          pattern: pattern,
          script: worker_name
        })
      else
        conn.post("zones/#{zone_id}/workers/routes", {
          pattern: pattern,
          script: worker_name
        })
      end
    end

    def delete_session_worker(slug)
      account_id = @config.cloudflare_account_id
      api_token = @config.cloudflare_api_token
      zone_id = @config.cloudflare_zone_id
      domain = @config.send(:load_env_var, "CLOUDFLARE_DOMAIN")
      return unless account_id && api_token

      worker_name = "kml-#{service_name}-#{slug}"

      conn = Faraday.new(url: "https://api.cloudflare.com/client/v4") do |f|
        f.request :json
        f.response :json
        f.headers["Authorization"] = "Bearer #{api_token}"
      end

      # Delete route first
      if zone_id && domain
        hostname = "#{slug}.#{domain}"
        pattern = "#{hostname}/*"

        response = conn.get("zones/#{zone_id}/workers/routes")
        routes = response.body.dig("result") || []
        existing = routes.find { |r| r["pattern"] == pattern }

        conn.delete("zones/#{zone_id}/workers/routes/#{existing['id']}") if existing
      end

      # Delete worker
      conn.delete("accounts/#{account_id}/workers/scripts/#{worker_name}")
    end

    def update_tunnel_with_sessions
      tunnel = load_tunnel_from_server
      return unless tunnel

      tunnel_id = tunnel[:id]
      return unless tunnel_id

      # Build ingress from sessions only
      ingress = []

      domain = @config.send(:load_env_var, "CLOUDFLARE_DOMAIN")
      if domain
        SessionStore.all.each do |slug, data|
          ingress << { hostname: "#{slug}.#{domain}", service: "http://localhost:#{data[:port]}" }
        end
      end

      ingress << { service: "http_status:404" }

      # Update tunnel
      account_id = @config.cloudflare_account_id
      api_token = @config.cloudflare_api_token
      return unless account_id && api_token

      conn = Faraday.new(url: "https://api.cloudflare.com/client/v4") do |f|
        f.request :json
        f.response :json
        f.headers["Authorization"] = "Bearer #{api_token}"
      end

      conn.put("accounts/#{account_id}/cfd_tunnel/#{tunnel_id}/configurations", {
        config: { ingress: ingress }
      })

      # Sync DNS - add new, remove old
      zone_id = @config.cloudflare_zone_id
      if zone_id
        current_hostnames = ingress.map { |r| r[:hostname] }.compact
        sync_tunnel_dns(conn, zone_id, tunnel_id, current_hostnames)
      end

      # Restart cloudflared to pick up new config
      restart_cloudflared
    end

    def restart_cloudflared
      tunnel = load_tunnel_from_server
      return unless tunnel

      token = tunnel[:token]
      return unless token

      remote_exec("pkill cloudflared 2>/dev/null || true")
      remote_exec("nohup cloudflared tunnel run --token '#{token}' > /tmp/cloudflared.log 2>&1 &")
    end

    def deploy
      print "[1/5] Provision server..."
      @ip = provision_or_find_server

      step(2, "Sync code", steps: 5) { sync_code(@ip) }
      step(3, "Install", steps: 5) { run_install(@ip) }
      step(4, "Start processes", steps: 5) { start_processes(@ip) }
      step(5, "Start tunnel", steps: 5) { start_tunnel(@ip) }

      puts "\n✓ Sandbox ready at #{@ip}"
      @ip
    end

    def destroy
      # Delete all sessions first
      sessions = SessionStore.all
      if sessions.any?
        puts "Deleting #{sessions.size} session(s)..."
        sessions.each_key do |slug|
          print "  #{slug}..."
          delete_session_worker(slug.to_s)
          SessionStore.delete(slug.to_s)
          puts " ✓"
        end
      end

      server = @hetzner.find_server(@server_name)
      tunnel = find_tunnel_by_name

      if tunnel
        delete_tunnel(tunnel)
        puts "✓ Tunnel deleted"
      else
        puts "No tunnel found."
      end

      if server
        puts "Deleting server #{server['id']}..."
        @hetzner.delete_server(server["id"])
        puts "✓ Server deleted"
      else
        puts "No server found."
      end
    end

    def snapshot_create
      # First, provision a fresh server with setup
      puts "Creating base server for snapshot..."

      # Delete existing snapshot if any
      existing = @hetzner.find_snapshot(SNAPSHOT_NAME)
      if existing
        print "Deleting existing snapshot..."
        @hetzner.delete_snapshot(existing["id"])
        puts " ✓"
      end

      # Create temporary server
      temp_name = "kml-snapshot-builder"
      user_data = @hetzner.cloud_init_script(@config.ssh_public_key)

      print "Creating server..."
      server = @hetzner.create_server(
        name: temp_name,
        user_data: user_data
      )
      server = wait_for_server(server["id"])
      ip = @hetzner.server_ip(server)
      puts " #{ip}"

      system("ssh-keygen", "-R", ip, out: File::NULL, err: File::NULL)

      print "Waiting for SSH..."
      wait_for_ssh(ip)
      puts " ✓"

      wait_for_cloud_init(ip)

      # Run all setup commands
      run_setup_commands(ip)

      # Create snapshot
      print "Creating snapshot..."
      @hetzner.create_snapshot(server["id"], SNAPSHOT_NAME)

      # Wait for snapshot to be ready
      loop do
        snap = @hetzner.find_snapshot(SNAPSHOT_NAME)
        break if snap && snap["status"] == "available"
        sleep 5
      end
      puts " ✓"

      # Delete temporary server
      print "Cleaning up..."
      @hetzner.delete_server(server["id"])
      puts " ✓"

      puts "\n✓ Snapshot '#{SNAPSHOT_NAME}' created"
    end

    def snapshot_from_server(server_name)
      server = @hetzner.find_server(server_name)
      raise Error, "Server '#{server_name}' not found. Use 'kml snapshot' to create from scratch." unless server

      # Delete existing snapshot if any
      existing = @hetzner.find_snapshot(SNAPSHOT_NAME)
      if existing
        print "Deleting existing snapshot..."
        @hetzner.delete_snapshot(existing["id"])
        puts " ✓"
      end

      # Create snapshot from server
      print "Creating snapshot from '#{server_name}'..."
      @hetzner.create_snapshot(server["id"], SNAPSHOT_NAME)

      # Wait for snapshot to be ready
      loop do
        snap = @hetzner.find_snapshot(SNAPSHOT_NAME)
        break if snap && snap["status"] == "available"
        sleep 5
      end
      puts " ✓"

      puts "\n✓ Snapshot '#{SNAPSHOT_NAME}' created from '#{server_name}'"
    end

    def snapshot_delete
      snapshot = @hetzner.find_snapshot(SNAPSHOT_NAME)
      if snapshot
        @hetzner.delete_snapshot(snapshot["id"])
        puts "✓ Snapshot deleted"
      else
        puts "No snapshot found."
      end
    end

    def delete_tunnel(tunnel)
      return unless tunnel

      tunnel_id = tunnel[:id]

      # Clean up DNS records first
      cleanup_all_tunnel_dns(tunnel_id)

      account_id = @config.cloudflare_account_id
      api_token = @config.cloudflare_api_token
      return unless tunnel_id && account_id && api_token

      conn = Faraday.new(url: "https://api.cloudflare.com/client/v4") do |f|
        f.request :json
        f.response :json
        f.headers["Authorization"] = "Bearer #{api_token}"
      end

      # Cleanup stale connections first
      conn.delete("accounts/#{account_id}/cfd_tunnel/#{tunnel_id}/connections")

      # Delete tunnel
      conn.delete("accounts/#{account_id}/cfd_tunnel/#{tunnel_id}")
    end

    def exec(command)
      remote_exec_stream("cd #{code_path} && #{command}")
    end

    def ssh
      server = @hetzner.find_server(@server_name)
      raise Error, "No sandbox server found" unless server

      ip = @hetzner.server_ip(server)
      Kernel.exec("ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}")
    end

    def logs
      remote_exec_stream("cd #{code_path} && overmind echo")
    end

    private

    def step(num, name, steps: 4)
      print "[#{num}/#{steps}] #{name}..."
      $stdout.flush
      yield
      puts " ✓"
    end

    def provision_or_find_server
      server = @hetzner.find_server(@server_name)

      if server
        ip = @hetzner.server_ip(server)
        puts " exists (#{ip})"
        return ip
      end

      puts ""

      # Check for existing snapshot
      snapshot = @hetzner.find_snapshot(SNAPSHOT_NAME)
      from_snapshot = !!snapshot

      user_data = @hetzner.cloud_init_script(@config.ssh_public_key)

      print "    Creating server#{from_snapshot ? ' (from snapshot)' : ''}..."
      server = @hetzner.create_server(
        name: @server_name,
        user_data: user_data,
        image: from_snapshot ? snapshot["id"].to_s : "ubuntu-24.04"
      )
      server = wait_for_server(server["id"])
      ip = @hetzner.server_ip(server)
      puts " #{ip}"

      system("ssh-keygen", "-R", ip, out: File::NULL, err: File::NULL)

      print "    Waiting for SSH..."
      wait_for_ssh(ip)
      puts " ok"

      # Wait for cloud-init to finish (just user creation)
      wait_for_cloud_init(ip)

      # Run setup commands if not from snapshot
      unless from_snapshot
        run_setup_commands(ip)
      end

      ip
    end

    def run_setup_commands(ip)
      total = SETUP_COMMANDS.length
      SETUP_COMMANDS.each_with_index do |step, idx|
        print "    [#{idx + 1}/#{total}] #{step[:name]}..."
        $stdout.flush
        success = run_remote_command(ip, step[:cmd])
        if success
          puts " ✓"
        else
          puts " ✗"
          raise Error, "Setup failed: #{step[:name]}"
        end
      end
    end

    def run_remote_command(ip, cmd)
      system(
        "ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
        "bash -l -c #{Shellwords.escape(cmd)}",
        out: File::NULL, err: File::NULL
      )
    end

    def wait_for_cloud_init(ip)
      loop do
        result = `ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no deploy@#{ip} cloud-init status 2>/dev/null`.strip
        break if result.include?("done") || result.include?("error")
        sleep 2
      end
    end

    def wait_for_server(id)
      loop do
        server = @hetzner.get_server(id)
        return server if server && server["status"] == "running"
        sleep 3
      end
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

    def sync_code(ip)
      system(
        "ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
        "mkdir -p #{code_path}",
        out: File::NULL
      )

      system(
        "rsync", "-az", "--delete",
        "--exclude=tmp", "--exclude=log", "--exclude=node_modules",
        "./", "deploy@#{ip}:#{code_path}/"
      ) or raise Error, "Failed to sync code"
    end

    def run_install(ip)
      puts ""
      @config.install.each do |cmd|
        puts "    $ #{cmd}"
        # Source mise before running command
        full_cmd = "export PATH=\"$HOME/.local/bin:$PATH\" && eval \"$(mise activate bash)\" && cd #{code_path} && #{cmd}"
        system(
          "ssh", "-tt", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
          "bash -c #{Shellwords.escape(full_cmd)}"
        ) or raise Error, "Install command failed: #{cmd}"
      end
    end

    def start_processes(ip)
      # Write Procfile from config
      procfile_content = @config.processes.map { |name, cmd| "#{name}: #{cmd}" }.join("\n")
      File.write("/tmp/Procfile.kml", procfile_content)
      system("scp", "-o", "StrictHostKeyChecking=no", "/tmp/Procfile.kml", "deploy@#{ip}:#{code_path}/Procfile", out: File::NULL)

      # Stop existing overmind
      remote_exec("cd #{code_path} && overmind quit 2>/dev/null || true")

      # Start overmind
      remote_exec("cd #{code_path} && PORT=3000 overmind start -D")
    end

    def start_tunnel(ip)
      # Create or load tunnel
      tunnel = load_or_create_tunnel
      return unless tunnel

      # Stop existing cloudflared
      remote_exec("pkill cloudflared 2>/dev/null || true")

      # Start cloudflared with token
      remote_exec("nohup cloudflared tunnel run --token '#{tunnel[:token]}' > /tmp/cloudflared.log 2>&1 &")
    end

    def load_or_create_tunnel
      tunnel = find_tunnel_by_name
      return tunnel if tunnel

      create_tunnel
    end

    def find_tunnel_by_name
      account_id = @config.cloudflare_account_id
      api_token = @config.cloudflare_api_token
      return unless account_id && api_token

      tunnel_name = "#{@config.service_name}-sandbox"

      conn = Faraday.new(url: "https://api.cloudflare.com/client/v4") do |f|
        f.request :json
        f.response :json
        f.headers["Authorization"] = "Bearer #{api_token}"
      end

      response = conn.get("accounts/#{account_id}/cfd_tunnel", { name: tunnel_name, is_deleted: false })
      tunnels = response.body.dig("result") || []

      return nil if tunnels.empty?

      t = tunnels.first
      { id: t["id"], name: t["name"], token: t["token"] }
    end

    def load_tunnel_from_server
      output = remote_exec_output("cat /home/deploy/.kml/tunnel.json 2>/dev/null || echo '{}'")
      tunnel = JSON.parse(output, symbolize_names: true) rescue {}
      tunnel[:id] ? tunnel : nil
    end

    def create_tunnel
      account_id = @config.cloudflare_account_id
      api_token = @config.cloudflare_api_token
      return unless account_id && api_token

      conn = Faraday.new(url: "https://api.cloudflare.com/client/v4") do |f|
        f.request :json
        f.response :json
        f.headers["Authorization"] = "Bearer #{api_token}"
      end

      tunnel_name = "#{@config.service_name}-sandbox"
      response = conn.post("accounts/#{account_id}/cfd_tunnel", {
        name: tunnel_name,
        tunnel_secret: SecureRandom.base64(32)
      })

      return unless response.body["success"]

      tunnel_id = response.body.dig("result", "id")
      token = response.body.dig("result", "token")

      tunnel = { id: tunnel_id, token: token, name: tunnel_name }

      # Save on server
      remote_exec("mkdir -p /home/deploy/.kml")
      remote_exec("cat > /home/deploy/.kml/tunnel.json << 'EOF'\n#{JSON.pretty_generate(tunnel)}\nEOF")

      tunnel
    end

    def update_tunnel_ingress(tunnel_id, hostname, service)
      account_id = @config.cloudflare_account_id
      api_token = @config.cloudflare_api_token
      zone_id = @config.cloudflare_zone_id
      return unless account_id && api_token

      conn = Faraday.new(url: "https://api.cloudflare.com/client/v4") do |f|
        f.request :json
        f.response :json
        f.headers["Authorization"] = "Bearer #{api_token}"
      end

      # Update tunnel ingress
      conn.put("accounts/#{account_id}/cfd_tunnel/#{tunnel_id}/configurations", {
        config: {
          ingress: [
            { hostname: hostname, service: service },
            { service: "http_status:404" }
          ]
        }
      })

      # Create/update DNS record for the hostname
      ensure_tunnel_dns(conn, zone_id, tunnel_id, hostname) if zone_id
    end

    def ensure_tunnel_dns(conn, zone_id, tunnel_id, hostname)
      # Check if record exists
      response = conn.get("zones/#{zone_id}/dns_records", { name: hostname, type: "CNAME" })
      records = response.body.dig("result") || []

      tunnel_target = "#{tunnel_id}.cfargotunnel.com"

      if records.empty?
        # Create new record
        conn.post("zones/#{zone_id}/dns_records", {
          type: "CNAME",
          name: hostname,
          content: tunnel_target,
          proxied: true
        })
      else
        # Update existing record
        record_id = records.first["id"]
        conn.put("zones/#{zone_id}/dns_records/#{record_id}", {
          type: "CNAME",
          name: hostname,
          content: tunnel_target,
          proxied: true
        })
      end
    end

    def sync_tunnel_dns(conn, zone_id, tunnel_id, current_hostnames)
      tunnel_target = "#{tunnel_id}.cfargotunnel.com"
      domain = @config.send(:load_env_var, "CLOUDFLARE_DOMAIN")

      # Get all DNS records pointing to this tunnel
      response = conn.get("zones/#{zone_id}/dns_records", { type: "CNAME", content: tunnel_target })
      existing_records = response.body.dig("result") || []

      # Delete records not in current_hostnames
      existing_records.each do |record|
        unless current_hostnames.include?(record["name"])
          conn.delete("zones/#{zone_id}/dns_records/#{record['id']}")
        end
      end

      # Ensure current hostnames exist
      current_hostnames.each do |hostname|
        ensure_tunnel_dns(conn, zone_id, tunnel_id, hostname)
      end
    end

    def cleanup_all_tunnel_dns(tunnel_id)
      return unless tunnel_id

      account_id = @config.cloudflare_account_id
      api_token = @config.cloudflare_api_token
      zone_id = @config.cloudflare_zone_id
      return unless account_id && api_token && zone_id

      conn = Faraday.new(url: "https://api.cloudflare.com/client/v4") do |f|
        f.request :json
        f.response :json
        f.headers["Authorization"] = "Bearer #{api_token}"
      end

      # Only delete DNS records for THIS specific tunnel
      tunnel_target = "#{tunnel_id}.cfargotunnel.com"
      response = conn.get("zones/#{zone_id}/dns_records", { type: "CNAME", content: tunnel_target })
      records = response.body.dig("result") || []

      records.each do |record|
        conn.delete("zones/#{zone_id}/dns_records/#{record['id']}")
      end
    end
  end
end
