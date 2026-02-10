# frozen_string_literal: true

require "io/console"

module Kml
  class Setup
    ENV_FILE = ".env"
    DEFAULT_ANTHROPIC_URL = "https://api.anthropic.com"

    def run
      puts "kml setup"
      puts "=" * 40
      puts

      credentials = {}

      # Hetzner
      credentials[:hetzner] = prompt_credential(
        name: "HETZNER_API_TOKEN",
        description: "Hetzner Cloud API token",
        help_url: "https://console.hetzner.cloud → Security → API Tokens",
        validator: ->(token) { validate_hetzner(token) }
      )

      # Anthropic endpoint (ask first, needed for validation)
      credentials[:anthropic_url] = prompt_value(
        name: "ANTHROPIC_BASE_URL",
        description: "Anthropic API endpoint",
        default: DEFAULT_ANTHROPIC_URL,
        help: "Press enter for default, or enter custom endpoint"
      )

      # Anthropic token
      @anthropic_url = credentials[:anthropic_url] || DEFAULT_ANTHROPIC_URL
      credentials[:anthropic] = prompt_credential(
        name: "ANTHROPIC_AUTH_TOKEN",
        description: "Anthropic API key/token",
        help_url: "https://console.anthropic.com → API Keys",
        validator: ->(key) { validate_anthropic(key, @anthropic_url) },
        optional: true
      )

      # GitHub (optional, auto-detected)
      github_token = detect_github_token
      if github_token
        puts "GitHub: Auto-detected from gh CLI"
      else
        credentials[:github] = prompt_credential(
          name: "GITHUB_TOKEN",
          description: "GitHub personal access token",
          help_url: "https://github.com/settings/tokens",
          validator: ->(token) { validate_github(token) },
          optional: true
        )
      end

      puts
      write_env_file(credentials)
      puts
      puts "Setup complete. Run 'kml deploy' to create your sandbox."
    end

    private

    def prompt_value(name:, description:, default:, help:)
      existing = load_existing(name)

      puts "#{description}"
      puts "  #{help}"

      if existing && existing != default
        print "  Current: #{existing} - keep? [Y/n] "
        answer = $stdin.gets&.strip&.downcase
        return existing if answer.empty? || answer == "y"
      end

      print "  #{name} [#{default}]: "
      value = $stdin.gets&.strip

      if value.nil? || value.empty?
        puts "  Using default: #{default}"
        return default
      end

      value
    end

    def prompt_credential(name:, description:, help_url:, validator:, optional: false)
      existing = load_existing(name)

      puts "#{description}"
      puts "  Get one at: #{help_url}"

      if existing
        print "  Current: #{mask(existing)} - keep? [Y/n] "
        answer = $stdin.gets&.strip&.downcase
        if answer.empty? || answer == "y"
          print "  Validating..."
          if validator.call(existing)
            puts " OK"
            return existing
          else
            puts " FAILED"
          end
        end
      end

      loop do
        print "  #{name}: "
        value = read_secret

        if value.empty?
          if optional
            puts "  Skipped"
            return nil
          else
            puts "  Required"
            next
          end
        end

        print "  Validating..."
        if validator.call(value)
          puts " OK"
          return value
        else
          puts " FAILED - try again"
        end
      end
    end

    def read_secret
      if $stdin.tty?
        value = $stdin.noecho(&:gets)&.strip || ""
        puts
      else
        value = $stdin.gets&.strip || ""
      end
      value
    end

    def mask(value)
      return "" if value.nil? || value.empty?
      "#{value[0..3]}#{"*" * [value.length - 8, 4].max}#{value[-4..]}"
    end

    def load_existing(name)
      return ENV[name] if ENV[name] && !ENV[name].empty?
      return unless File.exist?(ENV_FILE)

      File.read(ENV_FILE)[/^#{name}=(.+)$/, 1]&.strip
    end

    def detect_github_token
      token = `gh auth token 2>/dev/null`.strip
      token.empty? ? nil : token
    end

    def validate_hetzner(token)
      return false if token.nil? || token.empty?

      conn = Faraday.new(url: "https://api.hetzner.cloud/v1") do |f|
        f.response :json
        f.headers["Authorization"] = "Bearer #{token}"
      end

      response = conn.get("servers", { per_page: 1 })
      response.status == 200
    rescue
      false
    end

    def validate_anthropic(key, base_url)
      return false if key.nil? || key.empty?

      # Ensure base URL ends with slash for proper relative path resolution
      base_url = "#{base_url.chomp('/')}/"

      conn = Faraday.new(url: base_url) do |f|
        f.request :json
        f.response :json
        f.headers["x-api-key"] = key
        f.headers["anthropic-version"] = "2023-06-01"
      end

      # Use relative path (no leading slash) so Faraday appends to base URL
      response = conn.post("v1/messages") do |req|
        req.body = {
          model: "claude-3-haiku-20240307",
          max_tokens: 1,
          messages: [{ role: "user", content: "hi" }]
        }
      end

      response.status == 200
    rescue
      false
    end

    def validate_github(token)
      return false if token.nil? || token.empty?

      conn = Faraday.new(url: "https://api.github.com") do |f|
        f.response :json
        f.headers["Authorization"] = "Bearer #{token}"
      end

      response = conn.get("user")
      response.status == 200
    rescue
      false
    end

    def write_env_file(credentials)
      existing = File.exist?(ENV_FILE) ? File.read(ENV_FILE) : ""
      lines = existing.lines.map(&:chomp)

      updates = {
        "HETZNER_API_TOKEN" => credentials[:hetzner],
        "ANTHROPIC_BASE_URL" => credentials[:anthropic_url],
        "ANTHROPIC_AUTH_TOKEN" => credentials[:anthropic],
        "GITHUB_TOKEN" => credentials[:github]
      }.compact

      updates.each do |key, value|
        next unless value

        idx = lines.find_index { |l| l.start_with?("#{key}=") }
        if idx
          lines[idx] = "#{key}=#{value}"
        else
          lines << "#{key}=#{value}"
        end
      end

      File.write(ENV_FILE, lines.join("\n") + "\n")
      puts "Wrote #{ENV_FILE}"
    end
  end
end
