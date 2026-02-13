# frozen_string_literal: true

require "faraday"
require "faraday/multipart"
require "json"
require "stringio"

module Kml
  module Infra
    class Cloudflare
      # Cloudflare Worker for session authentication.
      #
      # Architecture:
      # - cloudflared tunnel runs INSIDE the Daytona sandbox, connecting to localhost:3000
      # - DNS points to tunnel: <slug>.example.com -> <tunnel-id>.cfargotunnel.com
      # - Worker intercepts requests for auth, then passes through to tunnel origin
      # - No Daytona preview URLs needed - tunnel handles the connection directly
      #
      # Flow:
      # 1. User visits https://slug.example.com?token=xxx
      # 2. Worker validates token, sets HttpOnly cookie, redirects to clean URL
      # 3. Subsequent requests use cookie for auth
      # 4. After auth, Worker passes through to tunnel origin (cloudflared -> localhost:3000)
      # 5. WebSocket upgrades work naturally since we just pass through the request
      #
      # Merge Architecture:
      # Apps can provide additional files, bindings, and HTML injection.
      # KML provides base auth logic, app provides additions, KML merges them.

      def initialize(api_token:, account_id:, zone_id:, domain:)
        @api_token = api_token
        @account_id = account_id
        @zone_id = zone_id
        @domain = domain
      end

      attr_reader :domain, :account_id, :zone_id, :api_token

      # Ensure DNS CNAME record exists for tunnel
      #
      # @param hostname [String] Full hostname (e.g., "my-app.example.com")
      # @param tunnel_id [String] Cloudflare tunnel ID
      def ensure_tunnel_dns(hostname:, tunnel_id:)
        tunnel_target = "#{tunnel_id}.cfargotunnel.com"

        records = get_dns_records(hostname:, type: "CNAME")

        if records.empty?
          create_dns_record(
            hostname:,
            type: "CNAME",
            content: tunnel_target,
            proxied: true
          )
        elsif records.first["content"] != tunnel_target
          update_dns_record(
            record_id: records.first["id"],
            hostname:,
            type: "CNAME",
            content: tunnel_target,
            proxied: true
          )
        end
      end

      # Ensure DNS CNAME record exists for worker routing
      #
      # @param hostname [String] Full hostname (e.g., "my-app.example.com")
      def ensure_worker_dns(hostname:)
        records = get_dns_records(hostname:, type: "CNAME")

        if records.empty?
          create_dns_record(
            hostname:,
            type: "CNAME",
            content: @domain,
            proxied: true
          )
        elsif records.first["content"] == "workers.dev"
          # Fix old incorrect record
          update_dns_record(
            record_id: records.first["id"],
            hostname:,
            type: "CNAME",
            content: @domain,
            proxied: true
          )
        end
      end

      # Deploy a Cloudflare Worker with optional app-provided additions
      #
      # The Worker validates access tokens and sets HttpOnly cookies for auth.
      # After auth, requests pass through to the tunnel origin (cloudflared in sandbox).
      #
      # Apps can provide:
      # - files: Hash of { "filename.js" => "content" } to bundle into worker
      # - bindings: Hash of { "VAR_NAME" => "value" } for env bindings
      # - injection: HTML string to inject into response body
      #
      # @param worker_name [String] Name of the worker
      # @param access_token [String] Session access token (required for auth)
      # @param hostname [String] Hostname for the worker route
      # @param files [Hash] Optional files to bundle { "name.js" => "content" }
      # @param bindings [Hash] Optional env bindings { "VAR" => "value" }
      # @param injection [String, nil] Optional HTML to inject into <body>
      def deploy_worker(worker_name:, access_token:, hostname:, files: {}, bindings: {}, injection: nil)
        script = build_worker_script(files:, injection:)
        all_bindings = build_bindings(access_token:, extra: bindings)

        upload_worker(
          worker_name:,
          script:,
          bindings: all_bindings,
          files:
        )

        create_or_update_worker_route(
          worker_name:,
          pattern: "#{hostname}/*"
        )
      end

      # Delete a Cloudflare Worker and its associated resources
      #
      # @param worker_name [String] Name of the worker
      # @param hostname [String] Hostname for cleanup
      def delete_worker(worker_name:, hostname:)
        pattern = "#{hostname}/*"

        # Delete route first
        routes = get_worker_routes
        existing = routes.find { |r| r["pattern"] == pattern }
        delete_worker_route(existing["id"]) if existing

        # Delete DNS record
        records = get_dns_records(hostname:, type: "CNAME")
        records.each { |r| delete_dns_record(r["id"]) }

        # Delete worker
        delete_worker_script(worker_name)
      rescue StandardError => e
        puts "Warning: cleanup failed: #{e.message}"
      end

      # Create or reuse a Cloudflare Tunnel for a session
      #
      # Each session gets its own tunnel to avoid routing conflicts.
      # Uses cloudflare-managed config so we can run with just `--token`.
      # If tunnel with same name exists, reuses it (updates config).
      #
      # @param tunnel_name [String] Name of the tunnel (e.g., "kml-myapp-session1")
      # @param hostname [String] Hostname for the tunnel (e.g., "my-session.example.com")
      # @return [Hash] { tunnel_id:, token: }
      def create_tunnel(tunnel_name:, hostname:)
        # Check if tunnel already exists
        existing = find_tunnel_by_name(tunnel_name)

        if existing
          tunnel_id = existing["id"]
        else
          # Create new tunnel with cloudflare-managed config
          tunnel_secret = SecureRandom.hex(32)
          response = connection.post("accounts/#{@account_id}/cfd_tunnel", {
            name: tunnel_name,
            tunnel_secret:,
            config_src: "cloudflare"
          })

          raise Kml::Error, "Failed to create tunnel: #{response.body['errors']}" unless response.body["success"]
          tunnel_id = response.body["result"]["id"]
        end

        # Set/update tunnel ingress configuration
        connection.put("accounts/#{@account_id}/cfd_tunnel/#{tunnel_id}/configurations", {
          config: {
            ingress: [
              { hostname:, service: "http://localhost:3000" },
              { service: "http_status:404" }
            ]
          }
        })

        # Get the token for running cloudflared
        token_response = connection.get("accounts/#{@account_id}/cfd_tunnel/#{tunnel_id}/token")
        token = token_response.body["result"]

        {
          tunnel_id:,
          token:
        }
      end

      # Find tunnel by name
      #
      # @param name [String] Tunnel name
      # @return [Hash, nil] Tunnel data or nil
      def find_tunnel_by_name(name)
        response = connection.get("accounts/#{@account_id}/cfd_tunnel", { name:, is_deleted: false })
        tunnels = response.body["result"] || []
        tunnels.first
      end

      # Delete a Cloudflare Tunnel
      #
      # @param tunnel_id [String] The tunnel ID to delete
      def delete_tunnel(tunnel_id:)
        return unless tunnel_id

        # Clean up stale connections first (required before deletion)
        connection.delete("accounts/#{@account_id}/cfd_tunnel/#{tunnel_id}/connections")

        # Now delete the tunnel
        response = connection.delete("accounts/#{@account_id}/cfd_tunnel/#{tunnel_id}")
        unless response.success?
          puts "Warning: failed to delete tunnel #{tunnel_id}: #{response.body}"
        end
      rescue StandardError => e
        puts "Warning: failed to delete tunnel #{tunnel_id}: #{e.message}"
      end

      # Build worker script with optional file imports and injection
      #
      # @param files [Hash] Files to import { "name.js" => "content" }
      # @param injection [String, nil] HTML to inject into body
      # @return [String] Worker script
      def build_worker_script(files: {}, injection: nil)
        # Generate imports for each file
        imports = files.keys.map do |filename|
          var_name = filename.sub(/\.js$/, "").gsub(/[^a-zA-Z0-9]/, "_")
          "import #{var_name} from './#{filename}';"
        end.join("\n")

        imports_block = imports.empty? ? "" : "#{imports}\n\n"
        response_block = injection ? injection_block(injection) : "return response;"

        <<~JS
          #{imports_block}function parseCookies(cookieHeader) {
            const cookies = {};
            if (!cookieHeader) return cookies;
            cookieHeader.split(";").forEach((cookie) => {
              const [name, ...rest] = cookie.trim().split("=");
              if (name) cookies[name] = rest.join("=");
            });
            return cookies;
          }

          export default {
            async fetch(request, env) {
              const url = new URL(request.url);
              const path = url.pathname;

              // Assets don't need auth - pass through to tunnel origin
              if (path.startsWith("/assets/") || path.startsWith("/icon")) {
                return fetch(request);
              }

              const cookies = parseCookies(request.headers.get("Cookie") || "");
              const tokenParam = url.searchParams.get("token");
              const cookieToken = cookies["kml_token"];

              const token = tokenParam || cookieToken;
              if (!token || token !== env.ACCESS_TOKEN) {
                return new Response("Not Found", { status: 404 });
              }

              // First visit with token - set cookie and redirect to clean URL
              // Skip redirect for WebSocket upgrades (ActionCable) - they need to pass through
              const isWebSocket = request.headers.get("Upgrade") === "websocket";
              if (tokenParam && !isWebSocket) {
                url.searchParams.delete("token");
                return new Response(null, {
                  status: 302,
                  headers: {
                    Location: url.toString(),
                    "Set-Cookie": `kml_token=${token}; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=86400`,
                    "Cache-Control": "no-store",
                  },
                });
              }

              // Pass through to tunnel origin and optionally transform response
              const response = await fetch(request);

              #{response_block}
            },
          };
        JS
      end

      # Build bindings array with ACCESS_TOKEN and optional extras
      #
      # @param access_token [String] Required auth token
      # @param extra [Hash] Additional bindings { "VAR" => "value" }
      # @return [Array] Bindings array for worker metadata
      def build_bindings(access_token:, extra: {})
        bindings = [
          { type: "secret_text", name: "ACCESS_TOKEN", text: access_token }
        ]

        extra.each do |name, value|
          bindings << { type: "plain_text", name: name.to_s, text: value.to_s }
        end

        bindings
      end

      private

        def connection
          @connection ||= Faraday.new(url: "https://api.cloudflare.com/client/v4") do |f|
            f.request :json
            f.response :json
            f.headers["Authorization"] = "Bearer #{@api_token}"
          end
        end

        def multipart_connection
          @multipart_connection ||= Faraday.new(url: "https://api.cloudflare.com/client/v4") do |f|
            f.request :multipart
            f.response :json
            f.headers["Authorization"] = "Bearer #{@api_token}"
          end
        end

        # DNS Records

        def get_dns_records(hostname:, type:)
          response = connection.get("zones/#{@zone_id}/dns_records", { name: hostname, type: })
          response.body.dig("result") || []
        end

        def create_dns_record(hostname:, type:, content:, proxied:)
          connection.post("zones/#{@zone_id}/dns_records", {
            type:,
            name: hostname,
            content:,
            proxied:
          })
        end

        def update_dns_record(record_id:, hostname:, type:, content:, proxied:)
          connection.put("zones/#{@zone_id}/dns_records/#{record_id}", {
            type:,
            name: hostname,
            content:,
            proxied:
          })
        end

        def delete_dns_record(record_id)
          connection.delete("zones/#{@zone_id}/dns_records/#{record_id}")
        end

        # Workers

        # Generate injection block for HTMLRewriter
        #
        # @param injection [String] HTML to inject (can contain ${var} template literals)
        # @return [String] JavaScript code
        def injection_block(injection)
          # Escape backticks and backslashes for template literal
          escaped = injection.gsub("\\", "\\\\\\\\").gsub("`", '\\`')

          <<~JS.strip
            const ct = response.headers.get("content-type") || "";
            if (!ct.includes("text/html")) return response;

            const html = `#{escaped}`;
            return new HTMLRewriter()
              .on("body", {
                element(el) {
                  el.append(html, { html: true });
                }
              })
              .transform(response);
          JS
        end

        # Upload worker with merged files
        #
        # @param worker_name [String] Worker name
        # @param script [String] Main worker script
        # @param bindings [Array] Worker bindings
        # @param files [Hash] Additional files to bundle
        def upload_worker(worker_name:, script:, bindings:, files: {})
          metadata = {
            main_module: "worker.js",
            bindings:
          }

          parts = {
            "worker.js" => multipart_file(script, "worker.js"),
            "metadata" => multipart_json(metadata)
          }

          # Add each app-provided file as a module that exports content as default
          files.each do |filename, content|
            # Export content as default string (for injection/use in worker)
            module_content = "export default #{content.to_json};"
            parts[filename] = multipart_file(module_content, filename)
          end

          multipart_connection.put(
            "accounts/#{@account_id}/workers/scripts/#{worker_name}",
            parts
          )
        end

        def multipart_file(content, filename)
          Faraday::Multipart::FilePart.new(
            StringIO.new(content),
            "application/javascript+module",
            filename
          )
        end

        def multipart_json(data)
          Faraday::Multipart::FilePart.new(
            StringIO.new(JSON.generate(data)),
            "application/json",
            "metadata.json"
          )
        end

        def delete_worker_script(worker_name)
          connection.delete("accounts/#{@account_id}/workers/scripts/#{worker_name}")
        end

        # Worker Routes

        def get_worker_routes
          response = connection.get("zones/#{@zone_id}/workers/routes")
          response.body.dig("result") || []
        end

        def create_or_update_worker_route(worker_name:, pattern:)
          routes = get_worker_routes
          existing = routes.find { |r| r["pattern"] == pattern }

          if existing
            connection.put("zones/#{@zone_id}/workers/routes/#{existing['id']}", {
              pattern:,
              script: worker_name
            })
          else
            connection.post("zones/#{@zone_id}/workers/routes", {
              pattern:,
              script: worker_name
            })
          end
        end

        def delete_worker_route(route_id)
          connection.delete("zones/#{@zone_id}/workers/routes/#{route_id}")
        end
    end
  end
end
