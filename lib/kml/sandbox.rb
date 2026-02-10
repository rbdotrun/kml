# frozen_string_literal: true

require "open3"

module Kml
  class Sandbox
    def initialize(hetzner:, config:)
      @hetzner = hetzner
      @config = config
      @server_name = "#{config.service_name}-sandbox"
    end

    def deploy
      ip = provision_or_find_server
      @config.generate_sandbox(ip: ip)
      @config.write_sandbox_config
      @config.write_sandbox_secrets

      sync_code(ip)
      run_kamal_setup
      ip
    end

    def destroy
      server = @hetzner.find_server(@server_name)
      if server
        puts "Deleting server #{server['id']}..."
        @hetzner.delete_server(server["id"])
        puts "Done."
      else
        puts "No server found."
      end
    end

    def exec(command)
      system("kamal", "app", "exec", "-d", "sandbox", "--reuse", command)
    end

    private

    def provision_or_find_server
      server = @hetzner.find_server(@server_name)

      if server
        ip = @hetzner.server_ip(server)
        puts "Server exists: #{ip}"
        clear_known_host(ip)
        return ip
      end

      puts "Provisioning server..."
      user_data = @hetzner.cloud_init_script(@config.ssh_public_key)

      server = @hetzner.create_server(
        name: @server_name,
        user_data: user_data
      )

      print "Waiting for server"
      server = @hetzner.wait_for_server(server["id"])
      ip = @hetzner.server_ip(server)
      puts " #{ip}"

      clear_known_host(ip)
      wait_for_ssh(ip)
      wait_for_cloud_init(ip)

      ip
    end

    def clear_known_host(ip)
      system("ssh-keygen", "-R", ip, out: File::NULL, err: File::NULL)
    end

    def wait_for_ssh(ip)
      print "Waiting for SSH"
      loop do
        result = system(
          "ssh", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no",
          "deploy@#{ip}", "true",
          out: File::NULL, err: File::NULL
        )
        break if result
        print "."
        sleep 5
      end
      puts " ready"
    end

    def wait_for_cloud_init(ip)
      print "Waiting for cloud-init"
      loop do
        output, = Open3.capture2(
          "ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
          "pgrep -f apt-get || echo done"
        )
        break if output.strip == "done"
        print "."
        sleep 5
      end
      puts " done"
    end

    def sync_code(ip)
      puts "Syncing code..."
      code_path = @config.code_path

      system(
        "ssh", "-o", "StrictHostKeyChecking=no", "deploy@#{ip}",
        "sudo mkdir -p #{code_path} && sudo chown deploy:deploy #{code_path}"
      )

      system(
        "rsync", "-az",
        "--exclude=.git", "--exclude=tmp", "--exclude=log", "--exclude=node_modules",
        "./", "deploy@#{ip}:#{code_path}/"
      )
    end

    def run_kamal_setup
      puts "Running kamal setup..."
      system("kamal", "setup", "-d", "sandbox")
    end
  end
end
