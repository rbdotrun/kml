# frozen_string_literal: true

require_relative "lib/kml/version"

Gem::Specification.new do |spec|
  spec.name = "kml"
  spec.version = Kml::VERSION
  spec.authors = ["Ben"]
  spec.email = ["ben@dee.mx"]

  spec.summary = "Kamal sandbox deployment tool"
  spec.description = "Deploy development sandboxes from existing Kamal production configs"
  spec.homepage = "https://github.com/rbrun/kml"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[test/ spec/ features/ .git appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = ["kml"]
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "faraday-multipart", "~> 1.0"
  spec.add_dependency "thor", "~> 1.3"
  spec.add_dependency "websocket-client-simple", "~> 0.8"
end
