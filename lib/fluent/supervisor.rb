#
# Fluentd
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#

require 'etc'
require 'fcntl'

require 'fluent/config'
require 'fluent/env'
require 'fluent/engine'
require 'fluent/log'
require 'fluent/plugin'
require 'fluent/rpc'
require 'fluent/system_config'
require 'serverengine'
require 'shellwords'

if Fluent.windows?
  require 'windows/library'
  require 'windows/system_info'
  include Windows::Library
  include Windows::SystemInfo
  require 'win32/ipc'
  require 'win32/event'
end

module Fluent
  module ServerModule
    def before_run
      @start_time = Time.now

      if config[:rpc_endpoint]
        @rpc_endpoint = config[:rpc_endpoint]
        @enable_get_dump = config[:enable_get_dump]
        run_rpc_server
      end
      install_supervisor_signal_handlers

      socket_manager_path = ServerEngine::SocketManager::Server.generate_path
      ServerEngine::SocketManager::Server.open(socket_manager_path)
      ENV['SERVERENGINE_SOCKETMANAGER_PATH'] = socket_manager_path.to_s
    end

    def after_run
      if Time.now - @start_time < 1
        $log.warn "process died within 1 second. exit."
      end

      stop_rpc_server if @rpc_endpoint
    end

    def run_rpc_server
      @rpc_server = RPC::Server.new(@rpc_endpoint, $log)

      # built-in RPC for signals
      @rpc_server.mount_proc('/api/processes.interruptWorkers') { |req, res|
        $log.debug "fluentd RPC got /api/processes.interruptWorkers request"
        Process.kill :INT, $$
        nil
      }
      @rpc_server.mount_proc('/api/processes.killWorkers') { |req, res|
        $log.debug "fluentd RPC got /api/processes.killWorkers request"
        Process.kill :TERM, $$
        nil
      }
      @rpc_server.mount_proc('/api/plugins.flushBuffers') { |req, res|
        $log.debug "fluentd RPC got /api/plugins.flushBuffers request"
        unless Fluent.windows?
          Process.kill :USR1, $$
        end
        nil
      }
      @rpc_server.mount_proc('/api/config.reload') { |req, res|
        $log.debug "fluentd RPC got /api/config.reload request"
        if Fluent.windows?
          # restart worker with auto restarting by killing
          kill_worker
        else
          Process.kill :HUP, $$
        end
        nil
      }
      @rpc_server.mount_proc('/api/config.dump') { |req, res|
        $log.debug "fluentd RPC got /api/config.dump request"
        $log.info "dump in-memory config"
        supervisor_dump_config_handler
        nil
      }

      @rpc_server.mount_proc('/api/config.getDump') { |req, res|
        $log.debug "fluentd RPC got /api/config.dump request"
        $log.info "get dump in-memory config via HTTP"
        res.body = supervisor_get_dump_config_handler
        [nil, nil, res]
      } if @enable_get_dump

      @rpc_server.start
    end

    def stop_rpc_server
      @rpc_server.shutdown
    end

    def install_supervisor_signal_handlers
      trap :USR1 do
        $log.debug "fluentd supervisor process get SIGUSR1"
        supervisor_sigusr1_handler
      end unless Fluent.windows?
    end

    def supervisor_sigusr1_handler
      if log = config[:logger_initializer]
        log.reopen!
      end

      if pid = config[:worker_pid]
        Process.kill(:USR1, pid)
        # don't rescue Erro::ESRSH here (invalid status)
      end
    end

    def kill_worker
      if pid = config[:worker_pid]
        if Fluent.windows?
          Process.kill :KILL, pid
        else
          Process.kill :INT, pid
        end
      end
    end

    def supervisor_dump_config_handler
      $log.info config[:fluentd_conf].to_s
    end

    def supervisor_get_dump_config_handler
      {conf: config[:fluentd_conf].to_s}
    end
  end

  module WorkerModule
    def spawn(process_manager)
      main_cmd = config[:main_cmd]
      @pm = process_manager.spawn(main_cmd)
    end

    def after_start
      config[:worker_pid] = @pm.pid
    end
  end

  class Supervisor
    def self.load_config(path, params = {})

      pre_loadtime = 0
      pre_loadtime = params['pre_loadtime'].to_i if params['pre_loadtime']
      pre_config_mtime = nil
      pre_config_mtime = params['pre_config_mtime'] if params['pre_config_mtime']
      config_mtime = File.mtime(path)

      # reuse previous config if last load time is within 5 seconds and mtime of the config file is not changed
      if Time.now - Time.at(pre_loadtime) < 5 and config_mtime == pre_config_mtime
        return params['pre_conf']
      end

      config_fname = File.basename(path)
      config_basedir = File.dirname(path)
      config_data = File.read(path)
      inline_config = params['inline_config']
      if inline_config == '-'
        config_data << "\n" << STDIN.read
      elsif inline_config
        config_data << "\n" << inline_config.gsub("\\n","\n")
      end
      fluentd_conf = Fluent::Config.parse(config_data, config_fname, config_basedir, params['use_v1_config'])
      system_config = SystemConfig.create(fluentd_conf)

      log_level = system_config.log_level || params['log_level']
      suppress_repeated_stacktrace = system_config.suppress_repeated_stacktrace || params['suppress_repeated_stacktrace']
      log_path = params['log_path']
      chuser = params['chuser']
      chgroup = params['chgroup']
      rpc_endpoint = system_config.rpc_endpoint
      enable_get_dump = system_config.enable_get_dump

      log_opts = {suppress_repeated_stacktrace: suppress_repeated_stacktrace}
      logger_initializer = Supervisor::LoggerInitializer.new(log_path, log_level, chuser, chgroup, log_opts)
      # this #init sets initialized logger to $log
      logger_initializer.init
      logger = $log

      daemonize = params.fetch('daemonize', false)
      main_cmd = params['main_cmd']

      se_config = {
          worker_type: 'spawn',
          workers: 1,
          log_stdin: false,
          log_stdout: false,
          log_stderr: false,
          enable_heartbeat: true,
          auto_heartbeat: false,
          logger: logger,
          log: logger.out,
          log_path: log_path,
          log_level: log_level,
          logger_initializer: logger_initializer,
          chuser: chuser,
          chgroup: chgroup,
          suppress_repeated_stacktrace: suppress_repeated_stacktrace,
          daemonize: daemonize,
          rpc_endpoint: rpc_endpoint,
          enable_get_dump: enable_get_dump,
          windows_daemon_cmdline: [ServerEngine.ruby_bin_path,
                                   File.join(File.dirname(__FILE__), 'daemon.rb'),
                                   ServerModule.name,
                                   WorkerModule.name,
                                   path,
                                   JSON.dump(params)],
          fluentd_conf: fluentd_conf,
          main_cmd: main_cmd,
      }
      pre_params = params.dup
      params['pre_loadtime'] = Time.now.to_i
      params['pre_config_mtime'] = config_mtime
      params['pre_conf'] = se_config
      # prevent pre_conf from being too big by reloading many times.
      pre_params['pre_conf'] = nil
      params['pre_conf'][:windows_daemon_cmdline][5] = JSON.dump(pre_params)

      return se_config
    end

    class LoggerInitializer
      def initialize(path, level, chuser, chgroup, opts)
        @path = path
        @level = level
        @chuser = chuser
        @chgroup = chgroup
        @opts = opts
      end

      def init
        if @path && @path != "-"
          @io = File.open(@path, "a")
          if @chuser || @chgroup
            chuid = @chuser ? ServerEngine::Daemon.get_etc_passwd(@chuser).uid : nil
            chgid = @chgroup ? ServerEngine::Daemon.get_etc_group(@chgroup).gid : nil
            File.chown(chuid, chgid, @path)
          end
        else
          @io = STDOUT
        end

        dl_opts = {}
        # subtract 1 to match serverengine daemon logger side logging severity.
        dl_opts[:log_level] = @level - 1
        logger = ServerEngine::DaemonLogger.new(@io, dl_opts)
        $log = Fluent::Log.new(logger, @opts)
        $log.enable_color(false) if @path
        $log.enable_debug if @level <= Fluent::Log::LEVEL_DEBUG
      end

      def stdout?
        @io == STDOUT
      end

      def reopen!
        if @path && @path != "-"
          @io.reopen(@path, "a")
        end
        self
      end

      def level=(level)
        @level = level
        $log.level = level
      end
    end

    def self.default_options
      {
        config_path: Fluent::DEFAULT_CONFIG_PATH,
        plugin_dirs: [Fluent::DEFAULT_PLUGIN_DIR],
        log_level: Fluent::Log::LEVEL_INFO,
        log_path: nil,
        daemonize: nil,
        libs: [],
        setup_path: nil,
        chuser: nil,
        chgroup: nil,
        suppress_interval: 0,
        suppress_repeated_stacktrace: true,
        without_source: false,
        use_v1_config: true,
        supervise: true,
        signame: nil,
        winsvcreg: nil,
      }
    end

    def initialize(opt)
      @daemonize = opt[:daemonize]
      @supervise = opt[:supervise]
      @config_path = opt[:config_path]
      @inline_config = opt[:inline_config]
      @use_v1_config = opt[:use_v1_config]
      @log_path = opt[:log_path]
      @dry_run = opt[:dry_run]
      @show_plugin_config = opt[:show_plugin_config]
      @libs = opt[:libs]
      @plugin_dirs = opt[:plugin_dirs]
      @chgroup = opt[:chgroup]
      @chuser = opt[:chuser]
      @rpc_server = nil
      @process_name = nil

      @log_level = opt[:log_level]
      @suppress_interval = opt[:suppress_interval]
      @suppress_config_dump = opt[:suppress_config_dump]
      @without_source = opt[:without_source]
      @signame = opt[:signame]

      @suppress_repeated_stacktrace = opt[:suppress_repeated_stacktrace]
      log_opts = {suppress_repeated_stacktrace: @suppress_repeated_stacktrace}
      @log = LoggerInitializer.new(@log_path, @log_level, @chuser, @chgroup, log_opts)
      @finished = false
    end

    def run_supervisor
      @log.init
      show_plugin_config if @show_plugin_config
      read_config
      set_system_config

      dry_run if @dry_run
      supervise
    end

    def options
      {
        'config_path' => @config_path,
        'pid_file' => @daemonize,
        'plugin_dirs' => @plugin_dirs,
        'log_path' => @log_path
      }
    end

    def run_worker
      begin
        require 'sigdump/setup'
      rescue Exception
        # ignore LoadError and others (related with signals): it may raise these errors in Windows
      end
      @log.init
      Process.setproctitle("worker:#{@process_name}") if @process_name

      show_plugin_config if @show_plugin_config
      read_config
      set_system_config

      install_main_process_signal_handlers

      $log.info "starting fluentd-#{Fluent::VERSION} without supervision"

      main_process do
        change_privilege
        init_engine
        run_configure
        run_engine
        exit 0
      end
    end

    private

    def dry_run
      $log.info "starting fluentd-#{Fluent::VERSION} as dry run mode"
      change_privilege
      init_engine
      run_configure
      exit 0
    rescue => e
      $log.error "dry run failed: #{e}"
      exit 1
    end

    def show_plugin_config
      $log.info "Show config for #{@show_plugin_config}"
      @system_config = SystemConfig.new
      init_engine
      name, type = @show_plugin_config.split(":")
      plugin = Plugin.__send__("new_#{name}", type)
      dumped_config = "\n"
      level = 0
      plugin.class.ancestors.reverse_each do |plugin_class|
        if plugin_class.respond_to?(:dump)
          $log.on_debug do
            dumped_config << plugin_class.name
            dumped_config << "\n"
            level = 1
          end
          dumped_config << plugin_class.dump(level)
        end
      end
      $log.info dumped_config
      exit 0
    rescue => e
      $log.error "show config failed: #{e}"
      exit 1
    end

    def supervise
      $log.info "starting fluentd-#{Fluent::VERSION}"

      if Fluent.windows?
        fluentd_spawn_cmd = ServerEngine.ruby_bin_path + " -Eascii-8bit:ascii-8bit "
        fluentd_spawn_cmd << ' "' + $0.gsub('"', '""') + '" '
        $fluentdargv.each{|a|
          fluentd_spawn_cmd << ('"' + a.gsub('"', '""') + '" ')
        }
      else
        fluentd_spawn_cmd = ServerEngine.ruby_bin_path + " -Eascii-8bit:ascii-8bit "
        fluentd_spawn_cmd << $0.shellescape + ' '
        $fluentdargv.each{|a|
          fluentd_spawn_cmd << (a.shellescape + " ")
        }
      end

      fluentd_spawn_cmd << ("--no-supervisor")
      $log.info "spawn command to main: " + fluentd_spawn_cmd

      params = {}
      params['main_cmd'] = fluentd_spawn_cmd
      params['daemonize'] = @daemonize
      params['inline_config'] = @inline_config
      params['log_path'] = @log_path
      params['log_level'] = @log_level
      params['chuser'] = @chuser
      params['chgroup'] = @chgroup
      params['use_v1_config'] = @use_v1_config
      params['suppress_repeated_stacktrace'] = @suppress_repeated_stacktrace

      se = ServerEngine.create(ServerModule, WorkerModule){
        Fluent::Supervisor.load_config(@config_path, params)
      }
      se.run
    end

    def install_main_process_signal_handlers
      # Fluentd worker process (worker of ServerEngine) don't use code in serverengine to set signal handlers,
      # because it does almost nothing.
      # This method is the only method to set signal handlers in Fluentd worker process.

      # When user use Ctrl + C not SIGINT, SIGINT is sent to all process in same process group.
      # ServerEngine server process will send SIGTERM to child(spawned) processes by that SIGINT, so
      # worker process SHOULD NOT do anything with SIGINT, SHOULD just ignore.
      trap :INT do
        $log.debug "fluentd main process get SIGINT"
      end

      trap :TERM do
        $log.debug "fluentd main process get SIGTERM"
        unless @finished
          @finished = true
          $log.debug "getting start to shutdown main process"
          Fluent::Engine.stop
        end
      end

      trap :USR1 do
        flush_buffer
      end unless Fluent.windows?
    end

    def flush_buffer
      $log.debug "fluentd main process get SIGUSR1"
      $log.info "force flushing buffered events"
      @log.reopen!

      # Creating new thread due to mutex can't lock
      # in main thread during trap context
      Thread.new {
        begin
          Fluent::Engine.flush!
          $log.debug "flushing thread: flushed"
        rescue Exception => e
          $log.warn "flushing thread error: #{e}"
        end
      }.run
    end

    def main_process(&block)
      Process.setproctitle("worker:#{@process_name}") if @process_name

      begin
        block.call
      rescue Fluent::ConfigError
        $log.error "config error", file: @config_path, error: $!.to_s
        $log.debug_backtrace
        unless @log.stdout?
          logger = ServerEngine::DaemonLogger.new(STDOUT)
          log = Fluent::Log.new(logger)
          log.level = @log_level
          console = log.enable_debug
          console.error "config error", file: @config_path, error: $!.to_s
          console.debug_backtrace
        end

      rescue
        $log.error "unexpected error", error: $!.to_s
        $log.error_backtrace
        unless @log.stdout?
          logger = ServerEngine::DaemonLogger.new(STDOUT)
          log = Fluent::Log.new(logger)
          log.level = @log_level
          console = log.enable_debug
          console.error "unexpected error", error: $!.to_s
          console.error_backtrace
        end
      end

      exit! 1
    end

    def read_config
      $log.info "reading config file", path: @config_path
      @config_fname = File.basename(@config_path)
      @config_basedir = File.dirname(@config_path)
      @config_data = File.read(@config_path)
      if @inline_config == '-'
        @config_data << "\n" << STDIN.read
      elsif @inline_config
        @config_data << "\n" << @inline_config.gsub("\\n","\n")
      end
      @conf = Fluent::Config.parse(@config_data, @config_fname, @config_basedir, @use_v1_config)
    end

    def set_system_config
      @system_config = SystemConfig.create(@conf) # @conf is set in read_config
      @system_config.apply(self)
    end

    def change_privilege
      ServerEngine::Daemon.change_privilege(@chuser, @chgroup)
    end

    def init_engine
      Fluent::Engine.init(@system_config)

      @libs.each {|lib|
        require lib
      }

      @plugin_dirs.each {|dir|
        if Dir.exist?(dir)
          dir = File.expand_path(dir)
          Fluent::Engine.add_plugin_dir(dir)
        end
      }
    end

    def run_configure
      Fluent::Engine.run_configure(@conf)
    end

    def run_engine
      Fluent::Engine.run
    end
  end
end
