# frozen_string_literal: true

require "shellwords"
require "open3"
require "stringio"
require "faraday"
require "faraday/multipart"

module Kml
  class Sandbox
    SNAPSHOT_NAME = "kml-base"

    DOCKERFILE = <<~DOCKERFILE
      FROM ubuntu:24.04

      ENV DEBIAN_FRONTEND=noninteractive
      ENV HOME=/home/daytona
      ENV PATH="/home/daytona/.local/bin:/home/daytona/.local/share/mise/shims:$PATH"

      # System dependencies + PostgreSQL + cloudflared
      RUN apt-get update && apt-get install -y \\
          curl git build-essential libssl-dev libreadline-dev zlib1g-dev \\
          libyaml-dev libffi-dev libgdbm-dev libncurses5-dev libgmp-dev \\
          libpq-dev postgresql postgresql-contrib \\
          tmux unzip ca-certificates gnupg sudo \\
          && curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb \\
          && dpkg -i /tmp/cloudflared.deb \\
          && rm /tmp/cloudflared.deb \\
          && rm -rf /var/lib/apt/lists/*

      # Create daytona user with sudo access
      RUN useradd -m -s /bin/bash daytona && echo "daytona ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

      # Configure PostgreSQL to allow local connections
      RUN echo "local all all trust" > /etc/postgresql/16/main/pg_hba.conf && \\
          echo "host all all 127.0.0.1/32 trust" >> /etc/postgresql/16/main/pg_hba.conf && \\
          echo "host all all ::1/128 trust" >> /etc/postgresql/16/main/pg_hba.conf

      # Install mise as daytona user
      USER daytona
      WORKDIR /home/daytona

      RUN curl https://mise.run | sh

      # Install ruby and node via mise
      RUN /home/daytona/.local/bin/mise use -g ruby@3.3 node@22 \\
          && /home/daytona/.local/bin/mise install

      # Install overmind
      RUN curl -L https://github.com/DarthSim/overmind/releases/download/v2.5.1/overmind-v2.5.1-linux-amd64.gz | gunzip > /home/daytona/.local/bin/overmind \\
          && chmod +x /home/daytona/.local/bin/overmind

      # Install Claude Code CLI
      RUN /home/daytona/.local/share/mise/shims/npm install -g @anthropic-ai/claude-code

      # Verify installations
      RUN /home/daytona/.local/share/mise/shims/ruby --version \\
          && /home/daytona/.local/share/mise/shims/node --version \\
          && /home/daytona/.local/share/mise/shims/claude --version

      # Set shell to bash with mise activated
      ENV BASH_ENV="/home/daytona/.bashrc"
      RUN echo 'eval "$(/home/daytona/.local/bin/mise activate bash)"' >> /home/daytona/.bashrc

      # Create app directory with proper permissions
      RUN mkdir -p /home/daytona/app && chown daytona:daytona /home/daytona/app

      WORKDIR /home/daytona/app
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

    def ensure_tunnel_dns(slug)
      zone_id = @config.cloudflare_zone_id
      api_token = @config.cloudflare_api_token
      domain = @config.send(:load_env_var, "CLOUDFLARE_DOMAIN")
      tunnel_id = @config.tunnel_id
      return unless zone_id && api_token && domain && tunnel_id

      hostname = "#{slug}.#{domain}"

      conn = Faraday.new(url: "https://api.cloudflare.com/client/v4") do |f|
        f.request :json
        f.response :json
        f.headers["Authorization"] = "Bearer #{api_token}"
      end

      # Check if record exists
      response = conn.get("zones/#{zone_id}/dns_records", { name: hostname, type: "CNAME" })
      records = response.body.dig("result") || []

      tunnel_target = "#{tunnel_id}.cfargotunnel.com"

      if records.empty?
        conn.post("zones/#{zone_id}/dns_records", {
          type: "CNAME",
          name: hostname,
          content: tunnel_target,
          proxied: true
        })
      elsif records.first["content"] != tunnel_target
        conn.put("zones/#{zone_id}/dns_records/#{records.first['id']}", {
          type: "CNAME",
          name: hostname,
          content: tunnel_target,
          proxied: true
        })
      end
    end

    def ensure_dns_record(conn, zone_id, hostname)
      domain = @config.send(:load_env_var, "CLOUDFLARE_DOMAIN")

      # Check if record exists
      response = conn.get("zones/#{zone_id}/dns_records", { name: hostname, type: "CNAME" })
      records = response.body.dig("result") || []

      # Point to zone apex - Cloudflare Workers route takes precedence when proxied
      if records.empty?
        conn.post("zones/#{zone_id}/dns_records", {
          type: "CNAME",
          name: hostname,
          content: domain,
          proxied: true
        })
      elsif records.first["content"] == "workers.dev"
        # Fix old incorrect record
        conn.put("zones/#{zone_id}/dns_records/#{records.first['id']}", {
          type: "CNAME",
          name: hostname,
          content: domain,
          proxied: true
        })
      end
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
          worker = Worker.new(config: @config, service_name: service_name)
          worker.delete(slug: slug.to_s)
          SessionStore.delete(slug.to_s)
          puts " ✓"
        end
      end

      puts "✓ All sandboxes destroyed (snapshot preserved)"
    end

    def snapshot_create
      puts "Creating snapshot #{snapshot_name}..."

      # Delete existing if any
      existing = @daytona.find_snapshot_by_name(snapshot_name)
      if existing
        print "Deleting existing snapshot..."
        @daytona.delete_snapshot(existing["id"])
        sleep 10  # Wait for deletion to propagate
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
