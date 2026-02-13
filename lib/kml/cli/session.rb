# frozen_string_literal: true

require "thor"

module Kml
  module Cli
    class Session < Thor
      desc "new SLUG", "Create new sandbox (no Claude yet)"
      def new(slug)
        config = Config.from_files
        Kml::Core::Store.create(slug)

        session = build_session_from_config(slug, config)
        session.start! do |event, data|
          case event
          when :sandbox_created
            Kml::Core::Store.update(slug, sandbox_id: data)
          end
        end

        # Save tunnel info after start completes
        Kml::Core::Store.update(slug,
          tunnel_id: session.tunnel_id,
          tunnel_token: session.tunnel_token
        )
      rescue Kml::Error => e
        puts "Error: #{e.message}"
        exit 1
      end

      desc "prompt SLUG PROMPT", "Run Claude in sandbox"
      option :resume, aliases: "-r", type: :string, desc: "Resume conversation UUID"
      def prompt(slug, prompt_text)
        config = Config.from_files
        session = build_session_from_store(slug, config)

        # Track conversation
        if options[:resume]
          Kml::Core::Store.update_conversation(slug, uuid: options[:resume], prompt: prompt_text)
        else
          Kml::Core::Store.add_conversation(slug, uuid: session.uuid, prompt: prompt_text)
        end

        session.run!(prompt: prompt_text, resume: !!options[:resume])
      rescue Kml::Error => e
        puts "Error: #{e.message}"
        exit 1
      end

      desc "list [SLUG]", "List sessions or conversations in a session"
      def list(slug = nil)
        config = Config.from_files

        if slug
          list_conversations(slug)
        else
          list_sessions(config)
        end
      rescue Kml::Error => e
        puts "Error: #{e.message}"
        exit 1
      end

      desc "stop SLUG", "Stop sandbox"
      def stop(slug)
        config = Config.from_files
        session = build_session_from_store(slug, config)
        session.stop!
      rescue Kml::Error => e
        puts "Error: #{e.message}"
        exit 1
      end

      desc "delete SLUG", "Delete session and sandbox"
      def delete(slug)
        config = Config.from_files
        session = build_session_from_store(slug, config)
        session.delete!
        Kml::Core::Store.delete(slug)
        puts "Session '#{slug}' deleted."
      rescue Kml::Error => e
        puts "Error: #{e.message}"
        exit 1
      end

      desc "ps SLUG", "Show process statuses"
      def ps(slug)
        config = Config.from_files
        session = build_session_from_store(slug, config)
        statuses = session.process_statuses

        if statuses.empty?
          puts "No processes running."
          return
        end

        puts format("%-20s %s", "PROCESS", "STATUS")
        puts "-" * 40
        statuses.each do |p|
          puts format("%-20s %s", p[:name], p[:status])
        end
      rescue Kml::Error => e
        puts "Error: #{e.message}"
        exit 1
      end

      desc "restart SLUG PROCESS", "Restart a process"
      def restart(slug, process_name)
        config = Config.from_files
        session = build_session_from_store(slug, config)

        print "Restarting #{process_name}..."
        if session.restart_process(process_name)
          puts " done"
        else
          puts " failed"
          exit 1
        end
      rescue Kml::Error => e
        puts "Error: #{e.message}"
        exit 1
      end

      desc "logs SLUG PROCESS", "Stream process logs"
      option :follow, aliases: "-f", type: :boolean, default: false, desc: "Follow log output"
      option :lines, aliases: "-n", type: :numeric, default: 100, desc: "Number of lines to show"
      def logs(slug, process_name)
        config = Config.from_files
        session = build_session_from_store(slug, config)

        session.process_logs(process_name, lines: options[:lines], follow: options[:follow]) do |line|
          puts line
          $stdout.flush
        end
      rescue Kml::Error => e
        puts "Error: #{e.message}"
        exit 1
      rescue Interrupt
        # Ctrl+C exits cleanly
        puts "\nStopped."
      end

      private

        def build_session_from_config(slug, config)
          data = Kml::Core::Store.find(slug)
          raise Kml::Error, "Session '#{slug}' not found" unless data

          daytona = Config.build_daytona(config)
          cloudflare = Config.build_cloudflare(config)
          ai = Config.build_ai(config)

          Kml::Core::Session.new(
            slug:,
            ai:,
            daytona:,
            cloudflare:,
            git_repo: config[:git_repo],
            git_token: config[:git_token],
            install: config[:install] || [],
            processes: config[:processes] || {},
            service_name: config[:service_name],
            sandbox_id: data[:sandbox_id],
            access_token: data[:access_token],
            created_at: data[:created_at],
            tunnel_id: data[:tunnel_id],
            tunnel_token: data[:tunnel_token]
          )
        end

        def build_session_from_store(slug, config)
          data = Kml::Core::Store.find(slug)
          raise Kml::Error, "Session '#{slug}' not found" unless data

          build_session_from_config(slug, config)
        end

        def list_conversations(slug)
          session_data = Kml::Core::Store.find(slug)
          raise Kml::Error, "Session '#{slug}' not found" unless session_data

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
        end

        def list_sessions(config)
          sessions = Kml::Core::Store.all
          if sessions.empty?
            puts "No sessions."
            return
          end

          daytona = Config.build_daytona(config)

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
              rescue StandardError
                status = "deleted?"
              end
            else
              status = "not started"
            end

            puts format("%-20s %-10s %-5d %s", slug_sym, status, convs, sandbox_id)
          end
        end
    end
  end
end
