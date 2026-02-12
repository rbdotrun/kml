# frozen_string_literal: true

module Kml
  module Runtime
    class Base
      # Returns the Dockerfile content for this runtime
      #
      # @return [String] Dockerfile content
      def dockerfile
        raise NotImplementedError, "#{self.class}#dockerfile must be implemented"
      end

      # Default install commands for this runtime
      #
      # @return [Array<String>] List of shell commands
      def default_install
        []
      end

      # Default process definitions for this runtime
      #
      # @return [Hash<String, String>] Process name => command pairs
      def default_processes
        {}
      end

      # Default port for the web server
      #
      # @return [Integer] Port number
      def default_port
        3000
      end
    end
  end
end
