# frozen_string_literal: true

module Kml
  module Ai
    class Base
      # Run AI coding assistant with the given prompt
      #
      # @param prompt [String] The prompt to send to the AI
      # @param session_id [String] Unique session identifier
      # @param resume [Boolean] Whether to resume an existing session
      # @param cwd [String] Working directory for the AI
      # @param executor [#call] Callable that executes commands and yields output
      # @yield [String] Yields each line of output
      def run(prompt:, session_id:, resume: false, cwd:, executor:, &block)
        raise NotImplementedError, "#{self.class}#run must be implemented"
      end

      # Environment variables required by this AI provider
      #
      # @return [Hash<String, String>] Environment variable name => value pairs
      def env_vars
        {}
      end

      # Build the command to execute for this AI provider
      #
      # @param session_flag [String] Session-related flags
      # @param prompt [String] The prompt
      # @return [String] Command to execute
      def build_command(session_flag, prompt)
        raise NotImplementedError, "#{self.class}#build_command must be implemented"
      end
    end
  end
end
