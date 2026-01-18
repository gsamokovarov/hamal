require "English"
require "json"
require "yaml"

module Hamal
  VERSION = "0.2"

  module Config
    def config_file = "config/deploy.yml"
    def deployed_revision = ARGV.first.then { _1 unless _1.to_s.start_with? "-" } || `git rev-parse HEAD`.strip
    def deployed_image = "#{app_name}:#{deployed_revision}"
    def deploy_config = @deploy_config ||= YAML.safe_load_file(config_file)
    def deploy_env = "production"
    def app_name = deploy_config.fetch "app_name"
    def app_repo = deploy_config.fetch "github_repo"
    def app_local_ports = deploy_config.fetch("local_ports").map(&:to_s)
    def server = deploy_config.fetch "server"
    def project_root = "/var/lib/#{app_name}"
    def aliases = deploy_config.fetch "aliases", {}
  end

  module Helpers
    include Config

    def on_server(user: :root, dir: nil, &) = RemoteExecutor.new(user, dir).instance_exec(&)

    def log(message)
      bold  = "\e[1m"
      green = "\e[32m"
      clear = "\e[0m"

      message = "#{bold}#{green}#{message}#{clear}" if $stdout.tty?
      puts message
    end
  end

  class RemoteExecutor
    include Helpers

    ExecResult = Struct.new :output, :exit_code do
      def success? = exit_code.zero?
    end

    def initialize(remote_user, remote_dir)
      @remote_user = remote_user
      @remote_dir = remote_dir

      raise "Invalid remote user #{@remote_user}" unless [:root, :rails].include? @remote_user
    end

    def sh(command, interactive: false, abort_on_error: false)
      dir_override = "cd #{@remote_dir};" if @remote_dir
      user_override = "runuser -u rails" if @remote_user == :rails
      ssh "#{dir_override} #{user_override} #{command}", interactive:, abort_on_error:
    end

    def sh!(command, interactive: false) = sh command, interactive:, abort_on_error: true

    def ssh(remote_command, abort_on_error:, interactive: false)
      remote_command = remote_command.gsub "'", %q('"'"')

      output =
        if interactive
          spawn "ssh -tt root@#{server} '#{remote_command}'", out: $stdout, err: $stderr, in: $stdin
          Process.wait
          nil
        else
          `ssh root@#{server} '#{remote_command}'`.strip
        end

      abort "Failed to execute `#{remote_command}` on `#{server}`" if abort_on_error && !$CHILD_STATUS.success?

      ExecResult.new output:, exit_code: $CHILD_STATUS.exitstatus
    end
  end

  module Stages
    include Helpers

    def build_new_image
      image_exists = on_server { sh "docker image inspect #{deployed_image}" }.success?
      if image_exists
        log "Using existing image #{deployed_image} for deploy"
        return
      end

      log "Building new image #{deployed_image} for deploy"

      source_dir = "#{project_root}/src/#{deployed_revision}"

      on_server do
        log "  Checking out source at revision #{deployed_revision}..."
        sh! "rm -rf #{source_dir}"
        sh! "git clone git@github.com:#{app_repo}.git #{source_dir}"
      end
      on_server dir: source_dir do
        sh! "git checkout #{deployed_revision}"

        log "  Building image..."
        sh! "docker build -t #{deployed_image} ."

        log "  Cleaning up source dir..."
        sh! "rm -rf #{source_dir}"
      end
    end

    def run_deploy_tasks
      log "Running migrations"

      on_server do
        sh! "docker run --rm " \
            "--label app=#{app_name} " \
            "--env-file #{project_root}/env_file " \
            "-e GIT_REVISION=#{deployed_revision} " \
            "-v #{project_root}/db:/rails/db/#{deploy_env} " \
            "-v #{project_root}/storage:/rails/storage " \
            "--entrypoint '/rails/bin/rails' " \
            "#{deployed_image} " \
            "-- db:migrate"
      end
    end

    def start_new_container
      log "Starting container for new version"

      # Determine which ports are currently bound and which are free for the new container
      running_containers = on_server { sh! "docker ps -q --filter label=app=#{app_name}" }.output.split
      bound_ports =
        running_containers.map do |container|
          port_settings = on_server { sh! "docker inspect --format '{{json .NetworkSettings.Ports}}' #{container}" }.output
          port_settings = JSON.parse port_settings
          (port_settings["3000/tcp"] || []).map { _1["HostPort"] }.compact
        end.flatten

      available_port = (app_local_ports - bound_ports).first
      abort "No TCP port available" unless available_port

      log "  Using port #{available_port} for new container"
      on_server do
        sh! "docker run -d --rm " \
            "--label app=#{app_name} " \
            "--env-file #{project_root}/env_file " \
            "-e GIT_REVISION=#{deployed_revision} " \
            "-v #{project_root}/db:/rails/db/#{deploy_env} " \
            "-v #{project_root}/storage:/rails/storage " \
            "-p 127.0.0.1:#{available_port}:3000 " \
            "#{deployed_image}"
      end

      [available_port, running_containers]
    end

    def switch_traffic(new_container_port)
      log "Switching traffic to new version"

      log "  Waiting for new version to become ready"
      health_checks = 1
      loop do
        new_container_ready = on_server { sh "curl -fs http://localhost:#{new_container_port}/healthz" }.success?
        break if new_container_ready

        abort "New container failed to start within 30 seconds, investigate!" if health_checks > 30

        health_checks += 1
        sleep 1
      end

      log "  Redirecting nginx to new version"
      on_server do
        sh! "ACTIVE_RAILS_PORT=#{new_container_port} envsubst < /etc/nginx/#{app_name}.conf.template > /etc/nginx/#{app_name}.conf"
        sh! "nginx -s reload"
      end
    end

    def stop_old_container(old_containers)
      log "Stopping old container"

      if old_containers.empty?
        log "  (none found)"
        return
      end

      on_server do
        sh! "docker kill -s SIGTERM #{old_containers.join ' '}"
      end
    end

    def clean_up
      log "Cleaning up"

      log "  Removing unused docker objects"
      on_server do
        sh! 'docker system prune --all --force --filter "until=24h"'
      end
    end
  end

  module Commands
    extend self

    include Stages

    def execute
      abort "Configure server in deploy config file" unless server

      case cmd = ARGV.shift
      when "deploy"
        deploy_command
      when "console"
        console_command
      when "logs"
        logs_command
      when "dump"
        dump_command
      when "ssh", "sudo"
        sudo_command
      when *aliases.keys
        alias_command(cmd)
      else
        help_command
      end
    end

    private

    def deploy_command
      build_new_image
      run_deploy_tasks
      new_container_port, old_containers = start_new_container
      switch_traffic new_container_port
      stop_old_container old_containers
      clean_up
    end

    def console_command
      image_exists = on_server { sh "docker image inspect #{deployed_image}" }.success?
      unless image_exists
        log "Cannot find #{deployed_image} for inspecting"
        return
      end

      log "Running Rails console"

      on_server do
        sh! "docker run --rm -it " \
            "--label app=#{app_name} " \
            "--env-file #{project_root}/env_file " \
            "-e GIT_REVISION=#{deployed_revision} " \
            "-v #{project_root}/db:/rails/db/#{deploy_env} " \
            "-v #{project_root}/storage:/rails/storage " \
            "--entrypoint '/rails/bin/rails' " \
            "#{deployed_image} " \
            "console", interactive: true
      end
    end

    def logs_command
      # Determine which ports are currently bound and which are free for the new container
      running_container, *other_containers = on_server { sh! "docker ps -q --filter label=app=#{app_name}" }.output.split
      abort "Multiple containers found, cannot follow logs: #{other_containers.inspect}" unless other_containers.empty?

      log "Following container #{running_container} logs"

      on_server do
        sh "docker logs -f #{running_container}", interactive: true
      end
    end

    def dump_command
      log "Dumping database"

      on_server do
        system "scp -O root@#{server}:/var/lib/#{app_name}/db/data.sqlite3 data.sqlite3", exception: true
      end
    end

    def sudo_command
      system "ssh root@#{server}", exception: true
    end

    def alias_command(alias_cmd)
      log "Running alias command '#{alias_cmd}' -> '#{aliases[alias_cmd]}'"

      on_server { sh aliases[alias_cmd] }
    end

    def help_command
      puts <<~HELP
        Usage: hamal [command]

        Commands:
          deploy   - Deploy the app to the server
          console  - Run rails console in the deployed container
          backup   - Backup the SQLite database from the server
          logs     - Follow logs of the deployed container
          ssh      - SSH into the server as administrator, alias: sudo
      HELP

      aliases.each { |cmd_name, cmd_exec| puts <<~HELP }
        #{'  ' << cmd_name}#{[9 - cmd_name.size, 1].max * ' '} - Alias command: #{cmd_exec}
      HELP
    end
  end
end
