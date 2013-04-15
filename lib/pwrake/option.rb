module Pwrake

  START_TIME = Time.now

  module Option

    DEFAULT_CONFFILES = ["pwrake_conf.yaml","PwrakeConf.yaml"]

    def option_data
      [
       'DRYRUN',
       'IGNORE_SYSTEM',
       'IGNORE_DEPRECATE',
       'LOAD_SYSTEM',
       'NOSEARCH',
       'RAKELIB',
       'SHOW_PREREQS',
       'SILENT',
       'TRACE',
       'TRACE_RULES',

       'FILESYSTEM',
       'SSH_OPTION',
       'PASS_ENV',
       'GNU_TIME',
       'HALT_QUEUE_WHILE_SEARCH',
       'SHOW_CONF',

       ['HOSTFILE','HOSTS'],
       ['LOGFILE','LOG',
        proc{|v|
          if v
            # turn trace option on
            Rake.application.options.trace = true
            if v == "" || !v.kind_of?(String)
              v = "Pwrake%Y%m%d-%H%M%S_%$.log"
            end
            START_TIME.strftime(v).sub("%$",Process.pid.to_s)
          end
        }],
       ['PROFILE',
        proc{|v|
          if v
            if v == "" || !v.kind_of?(String)
              v = "Pwrake%Y%m%d-%H%M%S_%$.csv"
            end
            START_TIME.strftime(v).sub("%$",Process.pid.to_s)
          end
        }],
       ['NUM_THREADS', proc{|v| v && v.to_i}],
       ['DISABLE_AFFINITY', proc{|v| v || ENV['AFFINITY']=='off'}],
       ['GFARM_BASEDIR', proc{|v| v || '/tmp'}],
       ['GFARM_PREFIX', proc{|v| v || "pwrake_#{ENV['USER']}"}],
       ['GFARM_SUBDIR', proc{|v| v || '/'}],
       #['MASTER_HOSTNAME', proc{|v| v || `hostname -f`.chomp}],
       ['WORK_DIR',proc{|v|
          v ||= '$HOME/%CWD_RELATIVE_TO_HOME'
          v.sub('%CWD_RELATIVE_TO_HOME',cwd_relative_to_home)
        }]
      ]
    end


    # ----- init -----

    def init_option
      @host_group = []
      init_options
      init_pass_env
      init_logger
      if @opts['SHOW_CONF']
        require "yaml"
        YAML.dump(@opts,$stdout)
        exit
      end
      @counter = Counter.new
    end

    attr_reader :core_list
    attr_reader :counter
    attr_reader :logfile
    attr_reader :queue_class
    attr_reader :shell_class


    def pwrake_options
      @opts
    end

    def init_options
      # Read pwrake_conf
      @pwrake_conf = Rake.application.options.pwrake_conf

      if @pwrake_conf
        if !File.exist?(@pwrake_conf)
          raise "Configuration file not found: #{@pwrake_conf}"
        end
      else
        @pwrake_conf = DEFAULT_CONFFILES.find{|fn| File.exist?(fn)}
      end

      if @pwrake_conf.nil?
        @yaml = {}
      else
        Log.debug "@pwrake_conf=#{@pwrake_conf}"
        require "yaml"
        @yaml = open(@pwrake_conf){|f| YAML.load(f) }
      end

      @opts = {'PWRAKE_CONF' => @pwrake_conf}

      option_data.each do |a|
        prc = nil
        keys = []
        case a
        when String
          keys << a
        when Array
          a.each do |x|
            case x
            when String
              keys << x
            when Proc
              prc = x
            end
          end
        end
        key = keys[0]
        val = search_opts(keys)
        val = prc.call(val) if prc
        @opts[key] = val if !val.nil?
        instance_variable_set("@"+key.downcase, val)
      end

      feedback_options [
       'DRYRUN',
       'IGNORE_SYSTEM',
       'IGNORE_DEPRECATE',
       'LOAD_SYSTEM',
       'NOSEARCH',
       'RAKELIB',
       'SHOW_PREREQS',
       'SILENT',
       'TRACE',
       'TRACE_RULES']
      Rake.verbose(true) if Rake.application.options.trace
      Rake.verbose(false) if Rake.application.options.silent
    end

    def feedback_options(a)
      a.each do |k|
        if v=@opts[k]
          m = (k.downcase+"=").to_sym
          Rake.application.options.send(m,v)
        end
      end
    end

    # Option order:
    #  command_option > ENV > pwrake_conf > DEFAULT_OPTIONS
    def search_opts(keys)
      val = Rake.application.options.send(keys[0].downcase.to_sym)
      return val if !val.nil?
      #
      keys.each do |k|
        val = ENV[k.upcase]
        return val if !val.nil?
      end
      #
      return nil if !@yaml
      keys.each do |k|
        val = @yaml[k.upcase]
        return val if !val.nil?
      end
      nil
    end

    def cwd_relative_to_home
      Pathname.pwd.relative_path_from(Pathname.new(ENV['HOME'])).to_s
    end

    def cwd_relative_if_under_home
      home = Pathname.new(ENV['HOME']).realpath
      path = pwd = Pathname.pwd.realpath
      while path != home
        if path.root?
          return pwd.to_s
        end
        path = path.parent
      end
      return pwd.relative_path_from(home).to_s
    end

    def init_pass_env
      if envs = @opts['PASS_ENV']
        pass_env = {}

        case envs
        when Array
          envs.each do |k|
            k = k.to_s
            if v = ENV[k]
              pass_env[k] = v
            end
          end
        when Hash
          envs.each do |k,v|
            k = k.to_s
            if v = ENV[k] || v
              pass_env[k] = v
            end
          end
        else
          raise "invalid option for PASS_ENV in pwrake_conf.yaml"
        end

        if pass_env.empty?
          @opts.delete('PASS_ENV')
        else
          @opts['PASS_ENV'] = pass_env
        end
      end
    end

    def init_logger
      if Rake.application.options.debug
        Log.level = Log::DEBUG
      elsif Rake.verbose.kind_of? TrueClass
        Log.level = Log::INFO
      else
        Log.level = Log::WARN
      end

      if @logfile
        logdir = File.dirname(@logfile)
        if !File.directory?(logdir)
          mkdir_p logdir
        end
        Log.open(@logfile)
        # turn trace option on
        #Rake.application.options.trace = true
      else
        Log.open($stdout)
      end
    end

    # ----- setup -----

    def setup_option
      set_hosts
      set_filesystem
    end

    def set_hosts
      if @hostfile && @num_threads
        raise "Cannot set `hostfile' and `num_threads' simultaneously"
      end
      if @hostfile
        require "socket"
        tmplist = []
        File.open(@hostfile) do |f|
          while l = f.gets
            l = $1 if /^([^#]*)#/ =~ l
            host, ncore, group = l.split
            if host
              begin
                host = Socket.gethostbyname(host)[0]
              rescue
                Log.info "FQDN not resoved : #{host}"
              end
              ncore = (ncore || 1).to_i
              group = (group || 0).to_i
              tmplist << ([host] * ncore.to_i)
              @host_group[group] ||= []
              @host_group[group] << host
            end
          end
        end
        #
        @core_list = []
        begin # alternative order
          sz = 0
          tmplist.each do |a|
            @core_list << a.shift if !a.empty?
            sz += a.size
          end
        end while sz>0
        @num_threads = @core_list.size
      else
        @num_threads = 1 if !@num_threads
        @core_list = ['localhost'] * @num_threads
      end
    end


    def set_filesystem
      if fn = @opts["PROFILE"]
        Shell.profiler.open(fn,@opts['GNU_TIME'])
      end

      @shell_opt = {
        :work_dir  => @opts['WORK_DIR'],
        :pass_env  => @opts['PASS_ENV'],
        :ssh_opt   => @opts['SSH_OPTION']
      }

      if @filesystem.nil?
        case mount_type
        when /gfarm2fs/
          @opts['FILESYSTEM'] = @filesystem = 'gfarm'
        end
      end

      case @filesystem
      when 'gfarm'
        require "pwrake/locality_aware_queue"
        require "pwrake/gfarm_feature"
        GfarmPath.subdir = @opts['GFARM_SUBDIR']
        @filesystem  = 'gfarm'
        @shell_class = GfarmShell
        @shell_opt.merge!({
          :work_dir  => Dir.pwd,
          :disable_steal => @opts['DISABLE_STEAL'],
          :single_mp => @opts['GFARM_SINGLE_MP'],
          :basedir   => @opts['GFARM_BASEDIR'],
          :prefix    => @opts['GFARM_PREFIX']
        })
        @queue_class = LocalityAwareQueue
      else
        @filesystem  = 'nfs'
        @shell_class = Shell
        @queue_class = TaskQueue
      end
    end

    def mount_type(d=nil)
      mtab = '/etc/mtab'
      if File.exist?(mtab)
        d ||= mountpoint_of_cwd
        open(mtab,'r') do |f|
          f.each_line do |l|
            if /#{d} (?:type )?(\S+)/o =~ l
              return $1
            end
          end
        end
      end
      nil
    end

    def mountpoint_of_cwd
      d = Pathname.pwd
      while !d.mountpoint?
        d = d.parent
      end
      d
    end

    # ----- finish -----

    def finish_option
      Log.close
    end

  end
end