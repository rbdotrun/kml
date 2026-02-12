# kml - Claude Code in the Cloud

kml runs Claude Code in Daytona sandboxes with Cloudflare tunnels for secure access.

## Architecture

```
lib/kml/
├── ai/                    # Pluggable AI backends
│   ├── base.rb            # Interface
│   └── claude_code.rb     # Claude Code via PTY streaming
│
├── runtime/               # Pluggable base images
│   ├── base.rb            # Interface
│   └── rails.rb           # Rails dockerfile (mise + ruby + postgres)
│
├── infra/                 # External services
│   ├── daytona.rb         # Daytona sandbox API
│   └── cloudflare.rb      # Tunnels + Workers + DNS
│
├── core/                  # Business logic (library-first, accepts hashes)
│   ├── session.rb         # Orchestrates sandbox + tunnel + worker
│   ├── sandbox.rb         # Snapshot lifecycle
│   └── store.rb           # JSON persistence (.kml/sessions.json)
│
└── cli/                   # CLI layer (reads files, builds hashes)
    ├── main.rb            # Entry point (deploy, destroy, snapshot)
    ├── session.rb         # Session subcommand (new, prompt, delete)
    └── config.rb          # Reads .kml.yml + .env → config hash
```

## How It Works

### Session Creation Flow

```
kml session new <slug>
    │
    ├─→ Create Daytona sandbox from snapshot
    ├─→ Clone git repo
    ├─→ Create Cloudflare tunnel (per-session, token-based)
    ├─→ Configure DNS: <slug>.domain.com → tunnel
    ├─→ Start PostgreSQL
    ├─→ Run install commands (bundle install, db:prepare)
    ├─→ Start app processes via overmind
    ├─→ Start cloudflared tunnel (--protocol http2 --token-file)
    └─→ Deploy Worker for auth (validates token, sets cookie)
```

### Request Flow

```
User → https://slug.domain.com?token=xxx
    │
    ├─→ Cloudflare Worker (validates token, sets HttpOnly cookie)
    ├─→ Cloudflare Tunnel (routes to cloudflared in sandbox)
    ├─→ cloudflared (connects to localhost:3000)
    └─→ Rails app
```

### Per-Session Tunnels

Each session gets its own Cloudflare tunnel to avoid routing conflicts:
- Tunnel name: `kml-<service>-<slug>`
- Config managed via Cloudflare API (not local files)
- Token stored in `.kml/sessions.json`
- Uses HTTP/2 protocol (QUIC blocked in Daytona sandbox)

## Testing with dummy-rails

The test app is at `/Users/ben/Desktop/dummy-rails`.

### Config File (.kml.yml)

```yaml
install:
  - bundle install
  - bin/rails db:prepare

ai:
  provider: claude_code
  env:
    ANTHROPIC_AUTH_TOKEN: "${ANTHROPIC_AUTH_TOKEN}"
    ANTHROPIC_BASE_URL: "${ANTHROPIC_BASE_URL}"

runtime: rails

processes:
  web: bin/rails server -b 0.0.0.0
  css: bin/rails tailwindcss:watch
```

### Required Environment Variables (.env)

```
DAYTONA_API_KEY=...
CLOUDFLARE_API_TOKEN=...
CLOUDFLARE_ACCOUNT_ID=...
CLOUDFLARE_ZONE_ID=...
CLOUDFLARE_DOMAIN=rb.run
ANTHROPIC_AUTH_TOKEN=...
ANTHROPIC_BASE_URL=...  # optional
```

### Testing Commands

```bash
# From dummy-rails directory, using local kml
cd /Users/ben/Desktop/dummy-rails

# Deploy snapshot (first time only)
ruby -I/Users/ben/Desktop/kml/lib -e "require 'kml'; Kml::Cli::Main.start(['deploy'])"

# Create a session
ruby -I/Users/ben/Desktop/kml/lib -e "require 'kml'; Kml::Cli::Main.start(['session', 'new', 'test-run'])"

# Run Claude prompt
ruby -I/Users/ben/Desktop/kml/lib -e "require 'kml'; Kml::Cli::Main.start(['session', 'prompt', 'test-run', 'your prompt here'])"

# List sessions
ruby -I/Users/ben/Desktop/kml/lib -e "require 'kml'; Kml::Cli::Main.start(['session', 'list'])"

# Delete session (cleans up sandbox + tunnel + worker)
ruby -I/Users/ben/Desktop/kml/lib -e "require 'kml'; Kml::Cli::Main.start(['session', 'delete', 'test-run'])"

# Destroy all sessions
ruby -I/Users/ben/Desktop/kml/lib -e "require 'kml'; Kml::Cli::Main.start(['destroy'])"
```

### Verify Tunnel Status

```bash
ruby -I/Users/ben/Desktop/kml/lib -e "
require 'faraday'
require 'kml'

config = Kml::Cli::Config.new
cf = config.to_h[:cloudflare]

conn = Faraday.new(url: 'https://api.cloudflare.com/client/v4') do |f|
  f.request :json
  f.response :json
  f.headers['Authorization'] = 'Bearer ' + cf[:api_token]
end

resp = conn.get(\"accounts/#{cf[:account_id]}/cfd_tunnel\", { is_deleted: false })
resp.body['result'].each do |t|
  next unless t['name'].start_with?('kml-')
  puts \"#{t['name']}: #{t['status']} (#{t['connections']&.length || 0} connections)\"
end
"
```

## Running Tests

```bash
cd /Users/ben/Desktop/kml
bundle exec rake test    # 115 tests, 176 assertions
bundle exec rubocop      # Should be clean
```

## Key Files

| File | Purpose |
|------|---------|
| `lib/kml/core/session.rb` | Main orchestrator - creates sandbox, tunnel, worker |
| `lib/kml/infra/cloudflare.rb` | Tunnel + Worker + DNS management |
| `lib/kml/infra/daytona.rb` | Sandbox API client |
| `lib/kml/cli/session.rb` | CLI commands for session management |
| `lib/kml/core/store.rb` | Persists session data to .kml/sessions.json |

## Troubleshooting

### Tunnel shows "down" or 0 connections
- Check cloudflared is running: look for `tunnel` session in sandbox
- Verify token is saved: `cat .kml/sessions.json | jq '.sessions["slug"].tunnel_token'`
- QUIC might be blocked: we use `--protocol http2` to force TCP

### 404 on session URL
- Worker might not be deployed: check worker routes in Cloudflare dashboard
- DNS might not be set: verify CNAME points to `<tunnel-id>.cfargotunnel.com`
- Token mismatch: ensure URL token matches stored access_token

### WebSocket/ActionCable fails
- Worker must not redirect WebSocket upgrades (check `isWebSocket` in worker script)
- Worker must pass through to tunnel origin: `return fetch(request)`
