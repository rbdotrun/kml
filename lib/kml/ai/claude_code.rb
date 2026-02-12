# frozen_string_literal: true

require "shellwords"
require "json"

module Kml
  module Ai
    class ClaudeCode < Base
      def initialize(auth_token:, base_url: nil)
        @auth_token = auth_token
        @base_url = base_url
      end

      def run(prompt:, session_id:, resume: false, cwd:, executor:, &block)
        session_flag = resume ? "--resume #{session_id}" : "--session-id #{session_id}"
        cmd = build_command(session_flag, prompt)

        output_started = false
        buffer = ""

        executor.call(cmd) do |chunk|
          # Skip until we see JSON output (filters command echo)
          if !output_started
            output_started = true if chunk.include?('{"type":')
            next unless output_started
          end

          # Strip ANSI codes and buffer
          clean = chunk.gsub(/\e\[[0-9;]*[a-zA-Z]/, "").gsub(/\e\][^\a]*\a/, "")
          buffer += clean

          # Emit complete JSON lines
          while (idx = buffer.index("\n"))
            line = buffer.slice!(0, idx + 1).strip
            next if line.empty?

            begin
              JSON.parse(line)
              block.call(line) if block
            rescue JSON::ParserError
              # Skip non-JSON lines
            end
          end
        end
      end

      def env_vars
        vars = { "ANTHROPIC_AUTH_TOKEN" => @auth_token }
        vars["ANTHROPIC_BASE_URL"] = @base_url if @base_url
        vars
      end

      def build_command(session_flag, prompt)
        env_exports = env_export_string
        env_part = env_exports.empty? ? "" : "#{env_exports} && "

        [
          'export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"',
          "&&",
          env_part,
          "claude",
          session_flag,
          "--dangerously-skip-permissions",
          "-p",
          "--verbose",
          "--output-format=stream-json",
          "--include-partial-messages",
          Shellwords.escape(prompt)
        ].join(" ").gsub(/\s+/, " ")
      end

      private

        def env_export_string
          lines = []
          lines << "export ANTHROPIC_AUTH_TOKEN=#{@auth_token}" if @auth_token
          lines << "export ANTHROPIC_BASE_URL=#{@base_url}" if @base_url
          lines.join(" && ")
        end
    end
  end
end
