# kml

CLI for managing Claude Code sandbox sessions on Daytona.

## Installation

```bash
gem install kml
```

## Configuration

Create a `.env` file in your project root:

```bash
DAYTONA_API_KEY=your_daytona_api_key
ANTHROPIC_AUTH_TOKEN=your_anthropic_token
ANTHROPIC_BASE_URL=https://api.anthropic.com  # optional
GITHUB_TOKEN=your_github_token  # for private repos
CLOUDFLARE_DOMAIN=yourdomain.com  # for tunnel URLs
```

Create a `kml.yml` config file:

```yaml
service: my-app
snapshot: my-snapshot-name
code_path: /home/daytona/app

processes:
  web: bin/rails server -b 0.0.0.0 -p 3000

install:
  - bundle install
  - bin/rails db:prepare

tunnel_id: your-cloudflare-tunnel-id # optional
tunnel_credentials: | # optional
  {"AccountTag":"...","TunnelID":"...","TunnelSecret":"..."}
```

## Commands

### Snapshot Management

```bash
kml snapshot build
```

Build a new Daytona snapshot from Dockerfile. Installs Ruby, Node, PostgreSQL, and Claude Code CLI.

```bash
kml snapshot status
```

Check the current snapshot build status.

```bash
kml snapshot logs
```

View snapshot build logs.

---

### Session Management

```bash
kml session new <slug>
```

Create a new sandbox session. This:

- Creates a Daytona sandbox from the snapshot
- Clones your git repository
- Starts PostgreSQL
- Runs install commands (bundle, db:prepare, etc.)
- Starts the app via Procfile
- Sets up Cloudflare tunnel (if configured)

Does NOT run Claude - use `kml session prompt` after.

```bash
kml session prompt <slug> "<prompt>"
```

Run Claude Code in the sandbox with a new conversation. Each prompt creates a new conversation UUID. Output streams to your terminal in JSON format.

```bash
kml session prompt <slug> -r <uuid> "<prompt>"
```

Resume an existing conversation. Claude remembers all previous context from that conversation.

```bash
kml session list
```

List all sessions with their status, conversation count, and sandbox ID.

```
SLUG                 STATUS     CONVS SANDBOX
--------------------------------------------------------------------------------
my-feature           started    3     dc6f47d3-c08b-4250-ad54-5003f5f42fb8
auth-work            stopped    1     a1b2c3d4-e5f6-7890-abcd-ef1234567890
```

```bash
kml session list <slug>
```

List all conversations in a specific session. Shows UUID, creation time, and last prompt.

```
UUID                                   CREATED              LAST PROMPT
--------------------------------------------------------------------------------
ec150334-53b0-4285-8a74-fb312f37f432   2026-02-11T15:09:01  Fix the authentication bug
4bcd6e19-6b2a-4e82-866a-35c66e36cfea   2026-02-11T15:09:23  Add dark mode support
```

```bash
kml session stop <slug>
```

Stop the sandbox (keeps worktree and data).

```bash
kml session delete <slug>
```

Delete the session completely - stops sandbox, removes from storage.

---

## Workflows

### Single Developer

```bash
# Create sandbox once
kml session new my-feature

# Run prompts (each creates new conversation)
kml session prompt my-feature "Fix the login bug"
kml session prompt my-feature "Add form validation"

# See all conversations
kml session list my-feature

# Resume a specific conversation
kml session prompt my-feature -r <uuid> "Continue with the fix"

# Done for the day
kml session stop my-feature

# Clean up
kml session delete my-feature
```

### Parallel Conversations

Run multiple prompts simultaneously in different terminals:

```bash
# Terminal 1
kml session prompt my-feature "Fix authentication"

# Terminal 2 (same sandbox, different conversation)
kml session prompt my-feature "Add dark mode"

# Terminal 3 (same sandbox, different conversation)
kml session prompt my-feature "Write tests for user model"
```

Each terminal:

- Gets its own conversation UUID
- Streams output to that terminal
- Can be resumed later independently

### Resume Workflow

```bash
# See what conversations exist
kml session list my-feature

# Pick one and continue
kml session prompt my-feature -r ec150334-53b0-4285-8a74-fb312f37f432 "What was I working on?"
```

---

## Output Format

All Claude output is JSON (stream-json format):

```json
{"type":"system","subtype":"init","session_id":"...","tools":[...]}
{"type":"assistant","message":{"content":[{"type":"text","text":"Hello!"}]}}
{"type":"result","subtype":"success","duration_ms":1234,"result":"Hello!"}
```

---

## Environment Variables

| Variable               | Required | Description                      |
| ---------------------- | -------- | -------------------------------- |
| `DAYTONA_API_KEY`      | Yes      | Daytona API key                  |
| `ANTHROPIC_AUTH_TOKEN` | Yes      | Anthropic API token for Claude   |
| `ANTHROPIC_BASE_URL`   | No       | Custom Anthropic API endpoint    |
| `GITHUB_TOKEN`         | No       | For cloning private repositories |
| `CLOUDFLARE_DOMAIN`    | No       | Domain for tunnel URLs           |

---

## Sandbox Details

Each sandbox includes:

- Ubuntu with mise (Ruby, Node version management)
- PostgreSQL (auto-started)
- Claude Code CLI (npm package)
- Your cloned repository
- Overmind process manager for Procfile

The app runs on port 3000 inside the sandbox. If Cloudflare tunnel is configured, accessible at `https://<slug>.<your-domain>`.
