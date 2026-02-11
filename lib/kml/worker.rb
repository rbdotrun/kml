# frozen_string_literal: true

require "faraday"
require "faraday/multipart"
require "json"

module Kml
  class Worker
    def initialize(config:, service_name:)
      @config = config
      @service_name = service_name
    end

    def deploy(slug:, access_token:, daytona_preview_url:, daytona_preview_token:)
      account_id = @config.cloudflare_account_id
      api_token = @config.cloudflare_api_token
      return unless account_id && api_token

      worker_name = "kml-#{@service_name}-#{slug}"

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

      script_path = File.join(__dir__, "worker_script.js")
      script_content = File.read(script_path)

      conn_multipart.put("accounts/#{account_id}/workers/scripts/#{worker_name}",
        "worker.js" => Faraday::Multipart::FilePart.new(
          StringIO.new(script_content),
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

    def delete(slug:)
      account_id = @config.cloudflare_account_id
      api_token = @config.cloudflare_api_token
      zone_id = @config.cloudflare_zone_id
      domain = @config.send(:load_env_var, "CLOUDFLARE_DOMAIN")
      return unless account_id && api_token

      worker_name = "kml-#{@service_name}-#{slug}"

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
    rescue
      # Ignore errors deleting worker
    end
  end
end
