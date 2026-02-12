# frozen_string_literal: true

require "io/console"

module Kml
  class Setup
    ENV_FILE = ".env"
    DEFAULT_ANTHROPIC_URL = "https://api.anthropic.com"
    DEFAULT_DAYTONA_ENDPOINT = "https://app.daytona.io/api"

    def run
      puts "kml setup"
      puts "=" * 40
      puts

      credentials = {}

      # Daytona
      credentials[:daytona] = prompt_credential(
        name: "DAYTONA_API_KEY",
        description: "Daytona API key",
        help_url: "https://app.daytona.io/dashboard/keys",
        validator: ->(token) { validate_daytona(token) }
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

      # Cloudflare (for custom domain auth)
      puts
      puts "Cloudflare settings (for custom domain auth):"
      credentials[:cf_account] = prompt_value(
        name: "CLOUDFLARE_ACCOUNT_ID",
        description: "Cloudflare Account ID",
        default: "",
        help: "Find in Cloudflare dashboard → Overview → Account ID"
      )

      if credentials[:cf_account] && !credentials[:cf_account].empty?
        credentials[:cf_token] = prompt_credential(
          name: "CLOUDFLARE_API_TOKEN",
          description: "Cloudflare API token (Workers + DNS permissions)",
          help_url: "https://dash.cloudflare.com/profile/api-tokens",
          validator: ->(token) { validate_cloudflare(token, credentials[:cf_account]) },
          optional: true
        )

        credentials[:cf_zone] = prompt_value(
          name: "CLOUDFLARE_ZONE_ID",
          description: "Cloudflare Zone ID",
          default: "",
          help: "Find in Cloudflare dashboard → Domain → Overview → Zone ID"
        )

        credentials[:cf_domain] = prompt_value(
          name: "CLOUDFLARE_DOMAIN",
          description: "Domain for session URLs",
          default: "",
          help: "e.g. rb.run (sessions will be slug.rb.run)"
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

        if existing && !existing.empty? && existing != default
          print "  Current: #{existing} - keep? [Y/n] "
          answer = $stdin.gets&.strip&.downcase
          return existing if answer.empty? || answer == "y"
        end

        print "  #{name}#{default.empty? ? '' : " [#{default}]"}: "
        value = $stdin.gets&.strip

        if value.nil? || value.empty?
          if default.empty?
            return nil
          else
            puts "  Using default: #{default}"
            return default
          end
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
        "#{value[0..3]}#{"*" * [ value.length - 8, 4 ].max}#{value[-4..]}"
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

      def validate_daytona(token)
        return false if token.nil? || token.empty?

        conn = Faraday.new(url: DEFAULT_DAYTONA_ENDPOINT) do |f|
          f.response :json
          f.headers["Authorization"] = "Bearer #{token}"
        end

        response = conn.get("snapshots", { limit: 1 })
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
            messages: [ { role: "user", content: "hi" } ]
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

      def validate_cloudflare(token, account_id)
        return false if token.nil? || token.empty?

        conn = Faraday.new(url: "https://api.cloudflare.com/client/v4") do |f|
          f.response :json
          f.headers["Authorization"] = "Bearer #{token}"
        end

        response = conn.get("accounts/#{account_id}")
        response.status == 200
      rescue
        false
      end

      def write_env_file(credentials)
        existing = File.exist?(ENV_FILE) ? File.read(ENV_FILE) : ""
        lines = existing.lines.map(&:chomp)

        updates = {
          "DAYTONA_API_KEY" => credentials[:daytona],
          "ANTHROPIC_BASE_URL" => credentials[:anthropic_url],
          "ANTHROPIC_AUTH_TOKEN" => credentials[:anthropic],
          "GITHUB_TOKEN" => credentials[:github],
          "CLOUDFLARE_ACCOUNT_ID" => credentials[:cf_account],
          "CLOUDFLARE_API_TOKEN" => credentials[:cf_token],
          "CLOUDFLARE_ZONE_ID" => credentials[:cf_zone],
          "CLOUDFLARE_DOMAIN" => credentials[:cf_domain]
        }.compact

        updates.each do |key, value|
          next unless value && !value.empty?

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
