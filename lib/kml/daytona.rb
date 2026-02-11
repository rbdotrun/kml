# frozen_string_literal: true

require "faraday"
require "json"
require "websocket-client-simple"

module Kml
  class Daytona
    DEFAULT_ENDPOINT = "https://app.daytona.io/api"

    def initialize(api_key:, endpoint: DEFAULT_ENDPOINT)
      @api_key = api_key
      @endpoint = endpoint.end_with?("/") ? endpoint : "#{endpoint}/"
    end

    # ============================================================
    # SNAPSHOTS
    # ============================================================

    def create_snapshot(name:, dockerfile_content:, entrypoint: nil, cpu: nil, memory: nil, disk: nil)
      post("snapshots", {
        name: name,
        buildInfo: { dockerfileContent: dockerfile_content },
        entrypoint: entrypoint,
        cpu: cpu,
        memory: memory,
        disk: disk
      }.compact)
    end

    def get_snapshot(id)
      get("snapshots/#{id}")
    end

    def find_snapshot_by_name(name)
      result = get("snapshots", { name: name })
      items = result["items"] || result
      items = [items] if items.is_a?(Hash)
      items&.find { |s| s["name"] == name }
    end

    def delete_snapshot(id)
      delete("snapshots/#{id}")
    end

    def wait_for_snapshot(id, timeout: 600, interval: 5)
      deadline = Time.now + timeout
      loop do
        snapshot = get_snapshot(id)
        state = snapshot["state"]
        return snapshot if %w[ready active].include?(state)
        raise Error, "Snapshot build failed: #{state}" if %w[error failed].include?(state)
        raise Error, "Timeout waiting for snapshot #{id}" if Time.now > deadline
        sleep interval
      end
    end

    def get_snapshot_build_logs(id)
      get("snapshots/#{id}/build-logs")
    end

    # ============================================================
    # SANDBOXES
    # ============================================================

    def create_sandbox(snapshot:, name: nil, env: {}, public: false, auto_stop_interval: 0)
      post("sandbox", {
        snapshot: snapshot,
        name: name,
        env: env.empty? ? nil : env,
        public: public,
        autoStopInterval: auto_stop_interval
      }.compact)
    end

    def get_sandbox(id)
      get("sandbox/#{id}")
    end

    def list_sandboxes
      get("sandbox")
    end

    def find_sandbox_by_name(name)
      sandboxes = list_sandboxes
      sandboxes&.find { |s| s["name"] == name }
    end

    def start_sandbox(id)
      post("sandbox/#{id}/start")
    end

    def stop_sandbox(id)
      post("sandbox/#{id}/stop")
    end

    def delete_sandbox(id)
      delete("sandbox/#{id}")
    end

    def set_sandbox_public(id, is_public)
      post("sandbox/#{id}/public/#{is_public}")
    end

    def wait_for_sandbox(id, timeout: 120, interval: 3)
      deadline = Time.now + timeout
      loop do
        sandbox = get_sandbox(id)
        state = sandbox["state"]
        return sandbox if state == "started" || state == "running"
        raise Error, "Sandbox failed: #{state}" if %w[error failed].include?(state)
        raise Error, "Timeout waiting for sandbox #{id}" if Time.now > deadline
        sleep interval
      end
    end

    # ============================================================
    # PREVIEW URLs
    # ============================================================

    def get_preview_url(sandbox_id:, port:)
      get("sandbox/#{sandbox_id}/ports/#{port}/preview-url")
    end

    def get_signed_preview_url(sandbox_id:, port:, expires_in: 300)
      get("sandbox/#{sandbox_id}/ports/#{port}/signed-preview-url", expiresInSeconds: expires_in)
    end

    # ============================================================
    # TOOLBOX - FILES
    # ============================================================

    def upload_file(sandbox_id:, path:, content:)
      upload("toolbox/#{sandbox_id}/toolbox/files/upload", file_path: path, content: content)
    end

    # ============================================================
    # TOOLBOX - PROCESS
    # ============================================================

    def execute_command(sandbox_id:, command:, cwd: nil, timeout: nil)
      post("toolbox/#{sandbox_id}/toolbox/process/execute", {
        command: command,
        cwd: cwd,
        timeout: timeout
      }.compact)
    end

    # ============================================================
    # TOOLBOX - SESSIONS (Background Processes)
    # ============================================================

    def create_session(sandbox_id:, session_id:)
      post("toolbox/#{sandbox_id}/toolbox/process/session", { sessionId: session_id })
    end

    def get_session(sandbox_id:, session_id:)
      get("toolbox/#{sandbox_id}/toolbox/process/session/#{session_id}")
    end

    def list_sessions(sandbox_id:)
      get("toolbox/#{sandbox_id}/toolbox/process/session")
    end

    def delete_session(sandbox_id:, session_id:)
      delete("toolbox/#{sandbox_id}/toolbox/process/session/#{session_id}")
    end

    def session_execute(sandbox_id:, session_id:, command:, run_async: true)
      post("toolbox/#{sandbox_id}/toolbox/process/session/#{session_id}/exec", {
        command: command,
        runAsync: run_async
      })
    end

    def stream_command_logs(sandbox_id:, session_id:, command_id:, &block)
      # Get signed preview URL for toolbox WebSocket port (bypasses CloudFront)
      preview = get_signed_preview_url(sandbox_id: sandbox_id, port: 2280)
      uri = URI.parse(preview["url"])
      ws_url = "wss://#{uri.host}/process/session/#{session_id}/command/#{command_id}/logs?follow=true"

      done = false
      ws = WebSocket::Client::Simple.connect(ws_url, headers: {
        "Authorization" => "Bearer #{@api_key}",
        "X-Daytona-Preview-Token" => preview["token"],
        "Content-Type" => "text/plain",
        "Accept" => "text/plain"
      })

      ws.on :message do |msg|
        if msg.type == :close
          done = true
        else
          block.call(msg.data.to_s) if block && msg.data
        end
      end

      ws.on :close do |_|
        done = true
      end

      ws.on :error do |e|
        $stderr.puts "WebSocket error: #{e}" if e
        done = true
      end

      # Wait for completion
      sleep 0.1 until done
    end

    def get_command_logs(sandbox_id:, session_id:, command_id:)
      get("toolbox/#{sandbox_id}/toolbox/process/session/#{session_id}/command/#{command_id}/logs")
    end

    # Stream logs via WebSocket to sandbox's internal toolbox service (port 2280)
    # This bypasses CloudFront and enables real-time streaming
    def stream_command_logs(sandbox_id:, session_id:, command_id:, &block)
      # Get signed preview URL for toolbox WebSocket port
      preview = get_signed_preview_url(sandbox_id: sandbox_id, port: 2280)
      preview_url = preview["url"]
      preview_token = preview["token"]

      # Convert to WebSocket URL
      uri = URI.parse(preview_url)
      ws_url = "#{uri.scheme == 'https' ? 'wss' : 'ws'}://#{uri.host}:#{uri.port}/process/session/#{session_id}/command/#{command_id}/logs?follow=true"

      done = false

      ws = WebSocket::Client::Simple.connect(ws_url, headers: {
        "Authorization" => "Bearer #{@api_key}",
        "X-Daytona-Preview-Token" => preview_token,
        "Content-Type" => "text/plain",
        "Accept" => "text/plain"
      })

      ws.on :message do |msg|
        if msg.type == :close
          done = true
        else
          block.call(msg.data.to_s) if block && msg.data
        end
      end

      ws.on :close do |_e|
        done = true
      end

      ws.on :error do |e|
        $stderr.puts "WebSocket error: #{e.message}" if e
        done = true
      end

      # Wait for completion
      sleep 0.1 until done
    end

    # ============================================================
    # TOOLBOX - GIT
    # ============================================================

    def git_clone(sandbox_id:, url:, path:, username: nil, password: nil, branch: nil)
      post("toolbox/#{sandbox_id}/toolbox/git/clone", {
        url: url,
        path: path,
        username: username,
        password: password,
        branch: branch
      }.compact)
    end

    private

    def connection
      @connection ||= Faraday.new(url: @endpoint) do |f|
        f.request :json
        f.response :json
        f.headers["Authorization"] = "Bearer #{@api_key}"
        f.headers["Content-Type"] = "application/json"
        f.options.timeout = 300
        f.options.open_timeout = 30
        f.adapter Faraday.default_adapter
      end
    end

    def get(path, params = {})
      response = connection.get(path, params)
      handle_response(response)
    end

    def post(path, body = {})
      response = connection.post(path, body)
      handle_response(response)
    end

    def delete(path)
      response = connection.delete(path)
      handle_response(response)
    end

    def upload(endpoint, file_path:, content:)
      multipart_connection = Faraday.new(url: @endpoint) do |f|
        f.request :multipart
        f.response :json
        f.headers["Authorization"] = "Bearer #{@api_key}"
        f.options.timeout = 300
        f.options.open_timeout = 30
        f.adapter Faraday.default_adapter
      end

      file = Faraday::Multipart::FilePart.new(
        StringIO.new(content),
        "application/octet-stream",
        File.basename(file_path)
      )

      response = multipart_connection.post("#{endpoint}?path=#{CGI.escape(file_path)}") do |req|
        req.body = { file: file }
      end
      handle_response(response)
    end

    def handle_response(response)
      return response.body if response.success?

      error_msg = case response.status
      when 400 then "Bad request"
      when 401 then "Unauthorized - check API key"
      when 403 then "Forbidden"
      when 404 then "Not found"
      when 408, 504 then "Timeout"
      when 500..599 then "Server error"
      else "Request failed"
      end

      body_info = response.body.is_a?(Hash) ? response.body["message"] || response.body["error"] : response.body.to_s[0..200]
      raise Error, "[#{response.status}] #{error_msg}: #{body_info}"
    end
  end
end
