module Pwrake

  class Profiler

    HEADER_FOR_PROFILE =
      %w[exec_id task_id task_name command
         start_time end_time elap_time host status]

    HEADER_FOR_GNU_TIME =
      %w[realtime systime usrtime maxrss averss memsz
         datasz stcksz textsz pagesz majflt minflt nswap ncswinv
         ncswvol ninp nout msgrcv msgsnd signum]

    def initialize
      @lock = Mutex.new
      @separator = ","
      @re_escape = /\s#{Regexp.escape(@separator)}/
      @gnu_time = false
      @id = 0
      @io = nil
    end

    attr_accessor :separator, :gnu_time

    def open(file,gnu_time=false,plot=false)
      @file = file
      @gnu_time = gnu_time
      @plot = plot
      @lock.synchronize do
        @io.close if @io != nil
        @io = File.open(file,"w")
      end
      _puts table_header
      t = Time.now
      profile(nil,'pwrake_profile_start',t,t)
    end

    def close
      t = Time.now
      profile(nil,'pwrake_profile_end',t,t)
      @lock.synchronize do
        @io.close if @io != nil
        @io = nil
      end
      if @plot
        require 'pwrake/report'
        Parallelism.plot_parallelism(@file)
      end
    end

    def _puts(s)
      @lock.synchronize do
        @io.puts(s) if @io
      end
    end

    def table_header
      a = HEADER_FOR_PROFILE
      if @gnu_time
        a += HEADER_FOR_GNU_TIME
      end
      a.join(@separator)
    end

    def command(cmd,terminator)
      if @gnu_time
        if /\*|\?|\{|\}|\[|\]|<|>|\(|\)|\~|\&|\||\\|\$|;|`|\n/ =~ cmd
          cmd = cmd.gsub(/'/,"'\"'\"'")
          cmd = "sh -c '#{cmd}'"
        end
        f = %w[%x %e %S %U %M %t %K %D %p %X %Z %F %R %W %c %w %I %O %r
               %s %k].join(@separator)
        "/usr/bin/time -o /dev/stdout -f '#{terminator}:#{f}' #{cmd}"
      else
        "#{cmd}\necho '#{terminator}':$? "
      end
    end #`

    def format_time(t)
      #t.utc.strftime("%F %T.%L")
      t.strftime("%F %T.%L")
    end

    def self.format_time(t)
      t.strftime("%F %T.%L")
    end

    def profile(task, cmd, start_time, end_time, host="", status="")
      id = @lock.synchronize do
        id = @id
        @id += 1
        id
      end
      if @io
        if task.kind_of? Rake::Task
          tname = task.name.inspect
          task_id = task.task_id
        else
          tname = ""
          task_id = ""
        end
        host = '"'+host+'"' if @re_escape =~ host
        _puts [id, task_id, tname, cmd.inspect,
               format_time(start_time),
               format_time(end_time),
               "%.3f" % (end_time-start_time),
               host, status].join(@separator)
      end
      if status==""
        1
      elsif @gnu_time
        /^([^,]*),/ =~ status
        Integer($1)
      else
        Integer(status)
      end
    end

  end
end
