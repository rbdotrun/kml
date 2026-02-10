# kml

Kamal sandbox deployment tool. Deploy development sandboxes from existing Kamal production configs.

## Installation

```bash
gem install kml
```

Or add to your Gemfile:

```ruby
gem "kml"
```

## Usage

Requires `HETZNER_API_TOKEN` in environment or `.env` file.

```bash
# Deploy sandbox (provision server + kamal setup)
kml deploy

# Destroy sandbox server
kml destroy

# Execute command in sandbox container
kml exec "bin/rails console"
kml exec "bin/rails db:migrate"
```

## How it works

1. Reads your existing `config/deploy.yml` (Kamal production config)
2. Provisions a Hetzner server with Docker pre-installed
3. Generates `config/deploy.sandbox.yml` with:
   - Volume-mounted code at `/opt/<service>/`
   - `RAILS_ENV=development`
   - PostgreSQL accessory
4. Syncs your local code to the server
5. Runs `kamal setup -d sandbox`

Code changes on the server are immediately visible on browser reload.

## Requirements

- Kamal installed locally
- Existing `config/deploy.yml` with PostgreSQL setup
- Hetzner API token
- SSH key at `~/.ssh/id_rsa.pub`
