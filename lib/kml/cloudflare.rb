# frozen_string_literal: true

require "faraday"
require "json"
require "securerandom"

module Kml
  class Cloudflare
    API_URL = "https://api.cloudflare.com/client/v4"

    def initialize(api_token:, account_id:, zone_id:, domain:)
      @api_token = api_token
      @account_id = account_id
      @zone_id = zone_id
      @domain = domain
      @conn = Faraday.new(url: API_URL) do |f|
        f.request :json
        f.response :json
        f.headers["Authorization"] = "Bearer #{api_token}"
      end
    end

    attr_reader :domain, :zone_id

    # Tunnel management

    def find_or_create_tunnel(name)
      existing = find_tunnel(name)
      return existing if existing

      secret = SecureRandom.base64(32)
      response = @conn.post("accounts/#{@account_id}/cfd_tunnel") do |req|
        req.body = { name: name, tunnel_secret: secret, config_src: "cloudflare" }
      end

      unless response.body["success"]
        raise Error, "Failed to create tunnel: #{response.body['errors']}"
      end

      result = response.body["result"]
      { id: result["id"], name: result["name"] }
    end

    def find_tunnel(name)
      response = @conn.get("accounts/#{@account_id}/cfd_tunnel", { name: name, is_deleted: false })
      result = response.body.dig("result", 0)
      return nil unless result
      { id: result["id"], name: result["name"] }
    end

    def delete_tunnel(tunnel_id)
      @conn.delete("accounts/#{@account_id}/cfd_tunnel/#{tunnel_id}/connections")
      @conn.delete("accounts/#{@account_id}/cfd_tunnel/#{tunnel_id}")
    end

    def get_tunnel_token(tunnel_id)
      response = @conn.get("accounts/#{@account_id}/cfd_tunnel/#{tunnel_id}/token")
      unless response.body["success"]
        raise Error, "Failed to get tunnel token: #{response.body['errors']}"
      end
      response.body["result"]
    end

    def get_tunnel_config(tunnel_id)
      response = @conn.get("accounts/#{@account_id}/cfd_tunnel/#{tunnel_id}/configurations")
      return {} unless response.body["success"]
      response.body.dig("result", "config") || {}
    end

    def put_tunnel_config(tunnel_id, ingress)
      response = @conn.put("accounts/#{@account_id}/cfd_tunnel/#{tunnel_id}/configurations") do |req|
        req.body = { config: { ingress: ingress } }
      end
      unless response.body["success"]
        raise Error, "Failed to update tunnel config: #{response.body['errors']}"
      end
      response.body["result"]
    end

    # DNS management

    def ensure_dns_record(hostname, tunnel_id)
      content = "#{tunnel_id}.cfargotunnel.com"
      existing = find_dns_record(hostname)

      if existing
        return existing if existing["content"] == content
        return update_dns_record(existing["id"], hostname, content)
      end

      create_dns_record(hostname, content)
    end

    def find_dns_record(hostname)
      response = @conn.get("zones/#{@zone_id}/dns_records", { name: hostname, type: "CNAME" })
      response.body.dig("result", 0)
    end

    def delete_dns_record(record_id)
      @conn.delete("zones/#{@zone_id}/dns_records/#{record_id}")
    end

    # Session ingress management

    def add_session_ingress(tunnel_id, slug, port)
      hostname = "sandbox-#{slug}.#{@domain}"

      config = get_tunnel_config(tunnel_id)
      ingress = config["ingress"] || []

      # Remove catch-all if present
      ingress = ingress.reject { |r| r["service"] == "http_status:404" }
      # Remove existing rule for this hostname
      ingress = ingress.reject { |r| r["hostname"] == hostname }
      # Add new rule
      ingress << { "hostname" => hostname, "service" => "http://localhost:#{port}" }
      # Add catch-all at end
      ingress << { "service" => "http_status:404" }

      put_tunnel_config(tunnel_id, ingress)
      ensure_dns_record(hostname, tunnel_id)

      hostname
    end

    def remove_session_ingress(tunnel_id, slug)
      hostname = "sandbox-#{slug}.#{@domain}"

      config = get_tunnel_config(tunnel_id)
      ingress = config["ingress"] || []

      ingress = ingress.reject { |r| r["hostname"] == hostname }
      ingress << { "service" => "http_status:404" } unless ingress.any? { |r| r["service"] == "http_status:404" }

      put_tunnel_config(tunnel_id, ingress)

      record = find_dns_record(hostname)
      delete_dns_record(record["id"]) if record
    end

    private

    def create_dns_record(hostname, content)
      response = @conn.post("zones/#{@zone_id}/dns_records") do |req|
        req.body = { type: "CNAME", name: hostname, content: content, proxied: true, ttl: 1 }
      end
      unless response.body["success"]
        raise Error, "Failed to create DNS: #{response.body['errors']}"
      end
      response.body["result"]
    end

    def update_dns_record(record_id, hostname, content)
      response = @conn.put("zones/#{@zone_id}/dns_records/#{record_id}") do |req|
        req.body = { type: "CNAME", name: hostname, content: content, proxied: true, ttl: 1 }
      end
      response.body["result"]
    end
  end
end
