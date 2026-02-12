# frozen_string_literal: true

module Kml
  module Runtime
    class Rails < Base
      DOCKERFILE = <<~DOCKERFILE
        FROM ubuntu:24.04

        ENV DEBIAN_FRONTEND=noninteractive
        ENV HOME=/home/daytona
        ENV PATH="/home/daytona/.local/bin:/home/daytona/.local/share/mise/shims:$PATH"

        # System dependencies + PostgreSQL + cloudflared
        RUN apt-get update && apt-get install -y \\
            curl git build-essential libssl-dev libreadline-dev zlib1g-dev \\
            libyaml-dev libffi-dev libgdbm-dev libncurses5-dev libgmp-dev \\
            libpq-dev postgresql postgresql-contrib \\
            tmux unzip ca-certificates gnupg sudo \\
            && curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb \\
            && dpkg -i /tmp/cloudflared.deb \\
            && rm /tmp/cloudflared.deb \\
            && rm -rf /var/lib/apt/lists/*

        # Create daytona user with sudo access
        RUN useradd -m -s /bin/bash daytona && echo "daytona ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

        # Configure PostgreSQL to allow local connections
        RUN echo "local all all trust" > /etc/postgresql/16/main/pg_hba.conf && \\
            echo "host all all 127.0.0.1/32 trust" >> /etc/postgresql/16/main/pg_hba.conf && \\
            echo "host all all ::1/128 trust" >> /etc/postgresql/16/main/pg_hba.conf

        # Install mise as daytona user
        USER daytona
        WORKDIR /home/daytona

        RUN curl https://mise.run | sh

        # Install ruby and node via mise
        RUN /home/daytona/.local/bin/mise use -g ruby@3.3 node@22 \\
            && /home/daytona/.local/bin/mise install

        # Install overmind
        RUN curl -L https://github.com/DarthSim/overmind/releases/download/v2.5.1/overmind-v2.5.1-linux-amd64.gz | gunzip > /home/daytona/.local/bin/overmind \\
            && chmod +x /home/daytona/.local/bin/overmind

        # Install Claude Code CLI
        RUN /home/daytona/.local/share/mise/shims/npm install -g @anthropic-ai/claude-code

        # Verify installations
        RUN /home/daytona/.local/share/mise/shims/ruby --version \\
            && /home/daytona/.local/share/mise/shims/node --version \\
            && /home/daytona/.local/share/mise/shims/claude --version

        # Set shell to bash with mise activated
        ENV BASH_ENV="/home/daytona/.bashrc"
        RUN echo 'eval "$(/home/daytona/.local/bin/mise activate bash)"' >> /home/daytona/.bashrc

        # Create app directory with proper permissions
        RUN mkdir -p /home/daytona/app && chown daytona:daytona /home/daytona/app

        WORKDIR /home/daytona/app
      DOCKERFILE

      def dockerfile
        DOCKERFILE
      end

      def default_install
        [ "bundle install", "bin/rails db:prepare" ]
      end

      def default_processes
        { "web" => "bin/rails server -b 0.0.0.0" }
      end
    end
  end
end
