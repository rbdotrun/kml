# frozen_string_literal: true

require "thor"

module Kml
  class SessionCLI < Thor
    desc "new SLUG [PROMPT]", "Create new session"
    option :detached, aliases: "-d", type: :boolean, desc: "Run in background"
    option :print, aliases: "-p", type: :boolean, desc: "Print mode: run prompt and exit"
    option :json, aliases: "-j", type: :boolean, desc: "JSON output mode"
    def new(slug, prompt = nil)
      # Validate prompt requirement before creating session
      if (options[:print] || options[:json] || options[:detached]) && prompt.nil?
        raise Error, "Prompt required for -p/-j/-d modes"
      end

      session_data = SessionStore.find_or_create(slug)
      session = build_session(session_data)

      session.start!(
        prompt: prompt,
        detached: options[:detached],
        print_mode: options[:print] || options[:detached],
        json_mode: options[:json]
      )
    rescue Error => e
      puts "Error: #{e.message}"
      exit 1
    end

    desc "continue SLUG [PROMPT]", "Continue existing session"
    option :detached, aliases: "-d", type: :boolean, desc: "Run in background"
    option :json, aliases: "-j", type: :boolean, desc: "JSON output mode"
    def continue(slug, prompt = nil)
      session_data = SessionStore.find(slug)
      raise Error, "Session '#{slug}' not found" unless session_data

      session = build_session(session_data)
      session.continue!(prompt: prompt, detached: options[:detached], json_mode: options[:json])
    rescue Error => e
      puts "Error: #{e.message}"
      exit 1
    end

    desc "stop SLUG", "Stop session (keep sandbox)"
    def stop(slug)
      session_data = SessionStore.find(slug)
      raise Error, "Session '#{slug}' not found" unless session_data

      session = build_session(session_data)
      session.stop!
    rescue Error => e
      puts "Error: #{e.message}"
      exit 1
    end

    desc "delete SLUG", "Delete session and all resources"
    def delete(slug)
      session_data = SessionStore.find(slug)
      raise Error, "Session '#{slug}' not found" unless session_data

      session = build_session(session_data)
      session.delete!
      puts "Session '#{slug}' deleted."
    rescue Error => e
      puts "Error: #{e.message}"
      exit 1
    end

    desc "list", "List all sessions"
    def list
      sessions = SessionStore.all
      if sessions.empty?
        puts "No sessions."
        return
      end

      daytona, sandbox = build_daytona_and_sandbox

      puts format("%-20s %-10s %s", "SLUG", "STATUS", "SANDBOX")
      puts "-" * 70

      sessions.each do |slug, data|
        status = "unknown"
        sandbox_id = data[:sandbox_id] || "-"

        if data[:sandbox_id]
          begin
            sb = daytona.get_sandbox(data[:sandbox_id])
            status = sb["state"] || "unknown"
          rescue
            status = "deleted?"
          end
        else
          status = "not started"
        end

        puts format("%-20s %-10s %s", slug, status, sandbox_id)
      end
    rescue Error => e
      puts "Error: #{e.message}"
      exit 1
    end

    private

    def build_daytona_and_sandbox
      api_key = ENV.fetch("DAYTONA_API_KEY") { load_env_var("DAYTONA_API_KEY") }
      raise Error, "DAYTONA_API_KEY not set" unless api_key

      daytona = Daytona.new(api_key: api_key)
      config = Config.new
      sandbox = Sandbox.new(daytona: daytona, config: config)

      [daytona, sandbox]
    end

    def build_session(data)
      daytona, sandbox = build_daytona_and_sandbox

      Session.new(
        slug: data[:slug],
        uuid: data[:uuid],
        sandbox_id: data[:sandbox_id],
        access_token: data[:access_token],
        created_at: data[:created_at],
        sandbox: sandbox,
        daytona: daytona
      )
    end

    def load_env_var(name)
      return unless File.exist?(".env")

      File.read(".env")[/#{name}=(.+)/, 1]&.strip
    end
  end
end
