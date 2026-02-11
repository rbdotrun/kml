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
            return fetch(env.DAYTONA_PREVIEW_URL + path, {
              headers: { 'x-daytona-preview-token': env.DAYTONA_PREVIEW_TOKEN }
            });
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

          // Proxy to Daytona with preview token
          const daytonaUrl = env.DAYTONA_PREVIEW_URL + url.pathname + url.search;
          return fetch(daytonaUrl, {
            method: request.method,
            headers: {
              ...Object.fromEntries(request.headers),
              'x-daytona-preview-token': env.DAYTONA_PREVIEW_TOKEN
            },
            body: request.body
          });
        }
      };
    JS

    SNAPSHOT_NAME = "kml-base"

    # Dockerfile for the base snapshot
    DOCKERFILE = <<~DOCKERFILE
      FROM ubuntu:24.04

      ENV DEBIAN_FRONTEND=noninteractive
      ENV PATH="/home/daytona/.local/bin:$PATH"

      # System packages
      RUN apt-get update && apt-get install -y \\
          git rsync build-essential libssl-dev libreadline-dev zlib1g-dev \\
          libyaml-dev tmux libpq-dev curl sudo postgresql-client \\
          && rm -rf /var/lib/apt/lists/*

      # Create daytona user with sudo (Daytona runs as this user)
      RUN useradd -m -s /bin/bash daytona && \\
          echo "daytona ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

      # Switch to daytona user for tool installation
      USER daytona
      WORKDIR /home/daytona

      # Install mise
      RUN curl -fsSL https://mise.run | sh

      # Configure mise
      RUN echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && \\
          echo 'eval "$($HOME/.local/bin/mise activate bash)"' >> ~/.bashrc && \\
          ~/.local/bin/mise settings set ruby.compile false

      # Install runtimes
      RUN ~/.local/bin/mise use -g ruby@3.4 && \\
          ~/.local/bin/mise use -g node@20

      # Install overmind
      USER root
      RUN curl -fsSL -L https://github.com/DarthSim/overmind/releases/download/v2.5.1/overmind-v2.5.1-linux-amd64.gz | gunzip > /usr/local/bin/overmind && \\
          chmod +x /usr/local/bin/overmind

      # Install claude-code
      USER daytona
      RUN ~/.local/bin/mise exec -- npm install -g @anthropic-ai/claude-code

      # Keep container running
      CMD ["sleep", "infinity"]
    DOCKERFILE

    def initialize(daytona:, config:)
      @daytona = daytona
      @config = config
    end

    def service_name
      @config.service_name
    end

    def code_path
      "/home/daytona/app"
    end

    def snapshot_name
      "kml-#{service_name}"
    end

    # Execute command in sandbox via Daytona API
    def exec_in_sandbox(sandbox_id, cmd, timeout: 300)
      # Wrap in sh -c for shell operators
      @daytona.execute_command(
        sandbox_id: sandbox_id,
        command: cmd,
        timeout: timeout
      )
    end

    def deploy_session_worker(slug, access_token, daytona_preview_url, daytona_preview_token)
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
          { type: "secret_text", name: "ACCESS_TOKEN", text: access_token },
          { type: "secret_text", name: "DAYTONA_PREVIEW_URL", text: daytona_preview_url },
          { type: "secret_text", name: "DAYTONA_PREVIEW_TOKEN", text: daytona_preview_token }
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

      # Ensure DNS record exists
      ensure_dns_record(conn, zone_id, hostname)
    end

    def ensure_dns_record(conn, zone_id, hostname)
      # Check if record exists
      response = conn.get("zones/#{zone_id}/dns_records", { name: hostname, type: "CNAME" })
      records = response.body.dig("result") || []

      # Point to workers.dev (Cloudflare will route via worker)
      if records.empty?
        conn.post("zones/#{zone_id}/dns_records", {
          type: "CNAME",
          name: hostname,
          content: "workers.dev",
          proxied: true
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

        # Delete DNS record
        response = conn.get("zones/#{zone_id}/dns_records", { name: hostname, type: "CNAME" })
        records = response.body.dig("result") || []
        records.each { |r| conn.delete("zones/#{zone_id}/dns_records/#{r['id']}") }
      end

      # Delete worker
      conn.delete("accounts/#{account_id}/workers/scripts/#{worker_name}")
    end

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
          dockerfile_content: DOCKERFILE,
          cpu: 2,
          memory: 4,
          disk: 10
        )
        snapshot_id = result["id"]
        @daytona.wait_for_snapshot(snapshot_id, timeout: 600)
        puts " done"
      end

      puts "[2/2] Snapshot ready: #{snapshot_name}"
      puts "\n✓ Sandbox ready. Use 'kml session new <slug>' to create sessions."
    end

    def destroy
      # Delete all sessions first
      sessions = SessionStore.all
      if sessions.any?
        puts "Deleting #{sessions.size} session(s)..."
        sessions.each_key do |slug|
          print "  #{slug}..."
          session_data = SessionStore.find(slug.to_s)
          if session_data && session_data[:sandbox_id]
            begin
              @daytona.delete_sandbox(session_data[:sandbox_id])
            rescue => e
              # Ignore errors deleting sandbox
            end
          end
          delete_session_worker(slug.to_s)
          SessionStore.delete(slug.to_s)
          puts " ✓"
        end
      end

      # Delete snapshot
      snapshot = @daytona.find_snapshot_by_name(snapshot_name)
      if snapshot
        print "Deleting snapshot..."
        @daytona.delete_snapshot(snapshot["id"])
        puts " ✓"
      else
        puts "No snapshot found."
      end

      puts "✓ Destroyed"
    end

    def snapshot_create
      puts "Creating snapshot #{snapshot_name}..."

      # Delete existing if any
      existing = @daytona.find_snapshot_by_name(snapshot_name)
      if existing
        print "Deleting existing snapshot..."
        @daytona.delete_snapshot(existing["id"])
        puts " ✓"
      end

      print "Building..."
      result = @daytona.create_snapshot(
        name: snapshot_name,
        dockerfile_content: DOCKERFILE,
        cpu: 2,
        memory: 4,
        disk: 10
      )
      snapshot_id = result["id"]
      @daytona.wait_for_snapshot(snapshot_id, timeout: 600)
      puts " ✓"

      puts "\n✓ Snapshot '#{snapshot_name}' created"
    end

    def snapshot_delete
      snapshot = @daytona.find_snapshot_by_name(snapshot_name)
      if snapshot
        @daytona.delete_snapshot(snapshot["id"])
        puts "✓ Snapshot deleted"
      else
        puts "No snapshot found."
      end
    end
  end
end
