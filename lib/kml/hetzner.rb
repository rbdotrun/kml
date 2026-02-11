# frozen_string_literal: true

require "faraday"
require "json"

module Kml
  class Hetzner
    API_URL = "https://api.hetzner.cloud/v1"

    def initialize(token:)
      @token = token
      @conn = Faraday.new(url: API_URL) do |f|
        f.request :json
        f.response :json
        f.headers["Authorization"] = "Bearer #{token}"
      end
    end

    def find_server(name)
      response = @conn.get("servers", { name: name })
      servers = response.body["servers"]
      servers&.first
    end

    def create_server(name:, server_type: "cx23", image: "ubuntu-24.04", location: "nbg1", user_data: nil)
      payload = {
        name: name,
        server_type: server_type,
        image: image,
        location: location
      }
      payload[:user_data] = user_data if user_data

      response = @conn.post("servers", payload)
      body = response.body

      if body["error"]
        raise Error, "Hetzner API error: #{body['error']['message']}"
      end

      body["server"]
    end

    def delete_server(id)
      @conn.delete("servers/#{id}")
    end

    def get_server(id)
      response = @conn.get("servers/#{id}")
      response.body["server"]
    end

    def server_ip(server)
      server&.dig("public_net", "ipv4", "ip")
    end

    def wait_for_server(id, timeout: 120)
      start = Time.now
      loop do
        server = get_server(id)
        return server if server["status"] == "running"
        raise Error, "Timeout waiting for server" if Time.now - start > timeout
        sleep 3
      end
    end

    def cloud_init_script(ssh_public_key)
      <<~YAML
        #cloud-config
        users:
          - name: deploy
            groups: sudo
            shell: /bin/bash
            sudo: ALL=(ALL) NOPASSWD:ALL
            ssh_authorized_keys:
              - #{ssh_public_key}
      YAML
    end

    def find_snapshot(description)
      response = @conn.get("images", { type: "snapshot" })
      images = response.body["images"] || []
      images.find { |img| img["description"] == description }
    end

    def create_snapshot(server_id, name)
      response = @conn.post("servers/#{server_id}/actions/create_image", {
        description: name,
        type: "snapshot",
        labels: { "kml" => "true" }
      })
      response.body
    end

    def delete_snapshot(id)
      @conn.delete("images/#{id}")
    end
  end
end
