# Core Library Architecture

## Goal
Make kml a library-first tool where the core accepts hash params directly, and CLI is just an overlay that reads files.

## Current Architecture
```
CLI → reads files (.kml.yml, .env) → Library also reads files → Creates sandbox
```

Problems:
- Library classes (Session, Sandbox, Config) read files directly
- Hard to use kml from Rails engine or other apps
- Config tied to file system

## Target Architecture
```
┌─────────────────────────────┐
│      Core Library           │
│  Session.new(params_hash)   │ ← Accepts hash params directly
│  Sandbox.new(params_hash)   │
└──────────────┬──────────────┘
               │
    ┌──────────┼──────────┐
    │          │          │
┌───▼────┐ ┌──▼──────┐ ┌─▼────────┐
│  CLI   │ │ Engine  │ │Other apps│
│ reads  │ │generates│ │          │
│ files  │ │ hashes  │ │          │
└────────┘ └─────────┘ └──────────┘
```

## Refactoring Steps

### 1. Session/Sandbox Classes
Accept hash params in constructor:
```ruby
Session.new(
  slug: "my-app",
  git_repo: "https://github.com/user/repo.git",
  git_branch: "main",
  github_token: "ghp_...",
  install: ["bundle install", "bin/rails db:prepare"],
  processes: {
    "web" => "bin/rails server -b 0.0.0.0",
    "css" => "bin/rails tailwindcss:watch"
  },
  env: {
    "RAILS_ENV" => "development",
    "ANTHROPIC_AUTH_TOKEN" => "..."
  }
)
```

### 2. Config Class
Convert to file-reader utility (used by CLI only):
```ruby
# CLI uses this
config = Config.from_files(root: Dir.pwd)
session = Session.new(**config.to_h)

# Engine calls directly
session = Session.new(
  slug: params[:service_name],
  git_repo: params[:git_repo],
  # ...
)
```

### 3. CLI
Thin wrapper that reads files and calls library:
```ruby
def new(slug)
  config = Config.from_files(root: Dir.pwd)
  session = Session.new(slug: slug, **config.to_h)
  session.start!
end
```

## JSON Structure (Engine → Library)
```json
{
  "service_name": "my-rails-app",
  "git_repo": "https://github.com/user/repo.git",
  "git_branch": "main",
  "github_token": "ghp_...",
  "install": [
    "bundle install",
    "bin/rails db:prepare"
  ],
  "processes": {
    "web": "bin/rails server -b 0.0.0.0",
    "css": "bin/rails tailwindcss:watch",
    "worker": "bundle exec sidekiq"
  },
  "env": {
    "RAILS_ENV": "development",
    "ANTHROPIC_AUTH_TOKEN": "..."
  }
}
```

## Benefits
- Library usable from any Ruby app
- CLI is just a convenient file-reader overlay
- Rails engine can call library directly
- Easier testing (pass hashes, no file mocking)
- service_name used as slug for everything (sessions, snapshots, subdomains, DB names)
