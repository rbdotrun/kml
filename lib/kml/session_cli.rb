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

      session_data = SessionStore.create(slug)
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
    def continue(slug, prompt = nil)
      session_data = SessionStore.find(slug)
      raise Error, "Session '#{slug}' not found" unless session_data

      session = build_session(session_data)
      session.continue!(prompt: prompt, detached: options[:detached])
    rescue Error => e
      puts "Error: #{e.message}"
      exit 1
    end

    desc "stop SLUG", "Stop session (keep worktree)"
    def stop(slug)
      session_data = SessionStore.find(slug)
      raise Error, "Session '#{slug}' not found" unless session_data

      session = build_session(session_data)
      session.stop!
      puts "Session '#{slug}' stopped."
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

      sandbox = build_sandbox
      puts format("%-20s %-10s %-6s %s", "SLUG", "STATUS", "PORT", "BRANCH")
      puts "-" * 60

      sessions.each do |slug, data|
        session = Session.new(
          slug: slug.to_s,
          uuid: data[:uuid],
          branch: data[:branch],
          port: data[:port],
          database: data[:database],
          created_at: data[:created_at],
          sandbox: sandbox
        )
        status = session.running? ? "running" : "stopped"
        puts format("%-20s %-10s %-6s %s", slug, status, data[:port], data[:branch])
      end
    rescue Error => e
      puts "Error: #{e.message}"
      exit 1
    end

    private

    def build_sandbox
      token = ENV.fetch("HETZNER_API_TOKEN") { load_env_var("HETZNER_API_TOKEN") }
      raise Error, "HETZNER_API_TOKEN not set. Run 'kml init' first." unless token

      hetzner = Hetzner.new(token: token)
      config = Config.new
      Sandbox.new(hetzner: hetzner, config: config)
    end

    def build_session(data)
      sandbox = build_sandbox
      Session.new(
        slug: data[:slug],
        uuid: data[:uuid],
        branch: data[:branch],
        port: data[:port],
        database: data[:database],
        created_at: data[:created_at],
        sandbox: sandbox
      )
    end

    def load_env_var(name)
      return unless File.exist?(".env")

      File.read(".env")[/#{name}=(.+)/, 1]&.strip
    end
  end
end
