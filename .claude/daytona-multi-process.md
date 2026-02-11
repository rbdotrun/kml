# Daytona Multi-Process & Command Execution

## The Problem

Daytona's `execute_command` API does NOT run commands through a shell by default. This means:

```bash
# THIS WILL NOT WORK as expected:
execute_command(command: "sleep 5 && echo done")
# Result: tries to run "sleep" with args ["5", "&&", "echo", "done"]

# THIS WILL NOT WORK:
execute_command(command: "dockerd > /tmp/log.txt 2>&1 &")
# Result: shell operators ignored, command fails
```

## The Solution: `sh -c` Wrapper

Always wrap commands that use shell operators in `sh -c '...'`:

```ruby
# CORRECT:
execute_command(command: "sh -c 'sleep 5 && echo done'")
execute_command(command: "sh -c 'dockerd > /tmp/log.txt 2>&1 &'")
```

## Shell Operators That Require Wrapping

| Operator   | Purpose              | Example          |
| ---------- | -------------------- | ---------------- |
| `&&`       | Run next if success  | `cmd1 && cmd2`   |
| `\|\|`     | Run next if failure  | `cmd1 \|\| cmd2` |
| `\|`       | Pipe output          | `cmd1 \| cmd2`   |
| `>`        | Redirect stdout      | `cmd > file`     |
| `2>&1`     | Redirect stderr      | `cmd 2>&1`       |
| `&`        | Background process   | `cmd &`          |
| `;`        | Sequential commands  | `cmd1; cmd2`     |
| `$()`      | Command substitution | `echo $(pwd)`    |
| `$((...))` | Arithmetic           | `echo $((1+1))`  |

## Running Background Processes

To start a service in the background:

```ruby
# Start dockerd in background
execute_command(
  sandbox_id: id,
  command: "sh -c 'dockerd > /tmp/dockerd.log 2>&1 &'"
)

# Start a web server in background
execute_command(
  sandbox_id: id,
  command: "sh -c 'nohup ruby /tmp/server.rb > /tmp/server.log 2>&1 &'"
)
```

## Chaining Multiple Commands

```ruby
# Start multiple services sequentially
setup_cmd = "dockerd > /tmp/dockerd.log 2>&1 & " \
            "sleep 5 && " \
            "docker run -d --name pg -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:15-alpine && " \
            "sleep 5 && " \
            "nohup ruby /tmp/server.rb > /tmp/server.log 2>&1 &"

execute_command(
  sandbox_id: id,
  command: "sh -c '#{setup_cmd.gsub("'", "'\\''")}'"  # Escape single quotes
)
```

## Escaping Single Quotes

When your command contains single quotes, escape them:

```ruby
cmd = "echo 'hello world'"
escaped = cmd.gsub("'", "'\\''")  # Results in: echo 'hello'\''world'
execute_command(command: "sh -c '#{escaped}'")
```

## Timeouts

Default Daytona timeout is ~10 seconds. For long-running commands:

```ruby
# Install dependencies (may take a while)
execute_command(
  sandbox_id: id,
  command: "npm install",
  timeout: 120  # 2 minutes
)

# Docker pull (can be slow)
execute_command(
  sandbox_id: id,
  command: "sh -c 'docker pull postgres:15-alpine'",
  timeout: 300  # 5 minutes
)
```

## Docker-in-Docker (DinD)

To run Docker containers inside a Daytona sandbox:

1. **Use the DinD base image**: `docker:28-dind`
2. **Start dockerd manually** (it's not running by default):

```ruby
# Start Docker daemon
execute_command(
  sandbox_id: id,
  command: "sh -c 'dockerd > /tmp/dockerd.log 2>&1 &'"
)

# Wait for dockerd to be ready
sleep 5

# Now you can run containers
execute_command(
  sandbox_id: id,
  command: "sh -c 'docker run -d --name myapp -p 3000:3000 myimage'"
)
```

## Checking Service Status

```ruby
# Check if a process is running
execute_command(
  sandbox_id: id,
  command: "sh -c 'pgrep -f dockerd && echo running || echo stopped'"
)

# Check if a port is listening
execute_command(
  sandbox_id: id,
  command: "sh -c 'curl -s http://localhost:3000 > /dev/null && echo OK || echo WAIT'"
)

# Read log file
execute_command(
  sandbox_id: id,
  command: "sh -c 'cat /tmp/server.log 2>/dev/null || echo No log yet'"
)
```

## Complete Example: Ruby + PostgreSQL

```ruby
# 1. Upload Ruby script
client.upload_file(
  sandbox_id: id,
  path: "/tmp/server.rb",
  content: server_code
)

# 2. Start all services
setup = "dockerd > /tmp/dockerd.log 2>&1 & " \
        "sleep 5 && " \
        "docker run -d --name pg -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:15-alpine && " \
        "sleep 5 && " \
        "nohup ruby /tmp/server.rb > /tmp/server.log 2>&1 &"

client.execute_command(
  sandbox_id: id,
  command: "sh -c '#{setup.gsub("'", "'\\''")}'"
  timeout: 120
)

# 3. Wait for server
sleep 5

# 4. Get preview URL and test
preview = client.get_preview_url(sandbox_id: id, port: 4567)
# curl -H "x-daytona-preview-token: #{preview['token']}" #{preview['url']}
```

## Common Gotchas

1. **No shell by default** - Always use `sh -c` for operators
2. **Timeout too short** - Set explicit timeout for slow commands
3. **Background process dies** - Use `nohup` to survive connection close
4. **Can't see output** - Redirect to log file, read later
5. **dockerd not running** - Must start manually in DinD image
6. **Single quotes in command** - Must escape with `'\''`
