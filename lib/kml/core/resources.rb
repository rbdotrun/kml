# frozen_string_literal: true

module Kml
  module Core
    # List all kml-managed resources across Daytona and Cloudflare
    class Resources
      def initialize(daytona:, cloudflare:)
        @daytona = daytona
        @cloudflare = cloudflare
      end

      # List all resources as a hash
      def list
        {
          sandboxes: list_sandboxes,
          tunnels: list_tunnels,
          workers: list_workers,
          dns_records: list_dns_records
        }
      end

      # List Daytona sandboxes
      def list_sandboxes
        @daytona.list_sandboxes.map do |sb|
          {
            id: sb["id"],
            name: sb["name"],
            state: sb["state"]
          }
        end
      rescue StandardError => e
        [{ error: e.message }]
      end

      # List Cloudflare tunnels (kml-* only)
      def list_tunnels
        return [] unless @cloudflare

        response = cloudflare_conn.get("accounts/#{@cloudflare.account_id}/cfd_tunnel", { is_deleted: false })
        tunnels = response.body["result"] || []

        tunnels
          .select { |t| t["name"].to_s.start_with?("kml-") }
          .map do |t|
            {
              id: t["id"],
              name: t["name"],
              status: t["status"],
              connections: t["connections"]&.length || 0
            }
          end
      rescue StandardError => e
        [{ error: e.message }]
      end

      # List Cloudflare workers (kml-* only)
      def list_workers
        return [] unless @cloudflare

        response = cloudflare_conn.get("accounts/#{@cloudflare.account_id}/workers/scripts")
        workers = response.body["result"] || []

        workers
          .select { |w| w["id"].to_s.start_with?("kml-") }
          .map do |w|
            {
              id: w["id"],
              created_on: w["created_on"],
              modified_on: w["modified_on"]
            }
          end
      rescue StandardError => e
        [{ error: e.message }]
      end

      # List Cloudflare DNS records (tunnel CNAMEs only)
      def list_dns_records
        return [] unless @cloudflare

        response = cloudflare_conn.get("zones/#{@cloudflare.zone_id}/dns_records")
        records = response.body["result"] || []

        records
          .select { |r| r["type"] == "CNAME" && r["content"].to_s.include?("cfargotunnel.com") }
          .map do |r|
            {
              id: r["id"],
              name: r["name"],
              content: r["content"]
            }
          end
      rescue StandardError => e
        [{ error: e.message }]
      end

      # Pretty print all resources
      def print
        data = list

        puts "=== Daytona Sandboxes ==="
        if data[:sandboxes].empty?
          puts "  (none)"
        else
          data[:sandboxes].each do |sb|
            if sb[:error]
              puts "  Error: #{sb[:error]}"
            else
              puts "  #{sb[:name]}: #{sb[:state]} (#{sb[:id]})"
            end
          end
        end

        puts "\n=== Cloudflare Tunnels ==="
        if data[:tunnels].empty?
          puts "  (none)"
        else
          data[:tunnels].each do |t|
            if t[:error]
              puts "  Error: #{t[:error]}"
            else
              puts "  #{t[:name]}: #{t[:status]} (#{t[:connections]} connections)"
            end
          end
        end

        puts "\n=== Cloudflare Workers ==="
        if data[:workers].empty?
          puts "  (none)"
        else
          data[:workers].each do |w|
            if w[:error]
              puts "  Error: #{w[:error]}"
            else
              puts "  #{w[:id]}"
            end
          end
        end

        puts "\n=== Cloudflare DNS Records ==="
        if data[:dns_records].empty?
          puts "  (none)"
        else
          data[:dns_records].each do |r|
            if r[:error]
              puts "  Error: #{r[:error]}"
            else
              puts "  #{r[:name]} -> #{r[:content]}"
            end
          end
        end

        data
      end

      private

      def cloudflare_conn
        @cloudflare_conn ||= Faraday.new(url: "https://api.cloudflare.com/client/v4") do |f|
          f.request :json
          f.response :json
          f.headers["Authorization"] = "Bearer #{@cloudflare.api_token}"
        end
      end
    end
  end
end
