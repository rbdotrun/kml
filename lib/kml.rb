# frozen_string_literal: true

require_relative "kml/version"

# Infrastructure
require_relative "kml/infra/daytona"
require_relative "kml/infra/cloudflare"

# AI Backends
require_relative "kml/ai/base"
require_relative "kml/ai/claude_code"

# Runtimes
require_relative "kml/runtime/base"
require_relative "kml/runtime/rails"

# Core
require_relative "kml/core/store"
require_relative "kml/core/sandbox"
require_relative "kml/core/session"

# CLI
require_relative "kml/setup"
require_relative "kml/cli/config"
require_relative "kml/cli/session"
require_relative "kml/cli/main"

module Kml
  class Error < StandardError; end
end
