# frozen_string_literal: true

require "thor"

module Kml
  class SessionCLI < Thor
    desc "new SLUG", "Create new sandbox (no Claude yet)"
    def new(slug)
      SessionStore.create(slug)
      session = build_session(slug)
      session.start!
    rescue Error => e
      puts "Error: #{e.message}"
      exit 1
    end

    desc "prompt SLUG PROMPT", "Run Claude in sandbox"
    option :resume, aliases: "-r", type: :string, desc: "Resume conversation UUID"
    def prompt(slug, prompt_text)
      session = build_session(slug)
      session.run!(prompt: prompt_text, resume_uuid: options[:resume])
    rescue Error => e
      puts "Error: #{e.message}"
      exit 1
    end

    desc "list [SLUG]", "List sessions or conversations in a session"
    def list(slug = nil)
      if slug
        # List conversations in this session
        session_data = SessionStore.find(slug)
        raise Error, "Session '#{slug}' not found" unless session_data

        convs = session_data[:conversations] || []
        if convs.empty?
          puts "No conversations in '#{slug}'."
          puts "Run: kml session prompt #{slug} \"your prompt\""
          return
        end

        puts format("%-38s %-20s %s", "UUID", "CREATED", "LAST PROMPT")
        puts "-" * 80
        convs.each do |c|
          puts format("%-38s %-20s %s", c[:uuid], c[:created_at][0..18], c[:last_prompt])
        end
      else
        # List all sessions
        sessions = SessionStore.all
        if sessions.empty?
          puts "No sessions."
          return
        end

        daytona, _sandbox = build_daytona_and_sandbox

        puts format("%-20s %-10s %-5s %s", "SLUG", "STATUS", "CONVS", "SANDBOX")
        puts "-" * 80

        sessions.each do |slug_sym, data|
          status = "unknown"
          sandbox_id = data[:sandbox_id] || "-"
          convs = (data[:conversations] || []).size

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

          puts format("%-20s %-10s %-5d %s", slug_sym, status, convs, sandbox_id)
        end
      end
    rescue Error => e
      puts "Error: #{e.message}"
      exit 1
    end

    desc "stop SLUG", "Stop sandbox"
    def stop(slug)
      session = build_session(slug)
      session.stop!
    rescue Error => e
      puts "Error: #{e.message}"
      exit 1
    end

    desc "delete SLUG", "Delete session and sandbox"
    def delete(slug)
      session = build_session(slug)
      session.delete!
      puts "Session '#{slug}' deleted."
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

    def build_session(slug)
      data = SessionStore.find(slug)
      raise Error, "Session '#{slug}' not found" unless data

      daytona, sandbox = build_daytona_and_sandbox

      Session.new(
        slug: data[:slug],
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
