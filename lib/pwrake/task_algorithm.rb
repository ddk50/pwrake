module Pwrake

  InvocationChain = Rake::InvocationChain
  TaskArguments = Rake::TaskArguments

  module TaskAlgorithm

    def location
      @location ||= []
    end

    def location=(a)
      @location = a
    end

    def task_id
      @task_id
    end

    def invoke_modify(*args)
      return if @already_invoked

      application.start_worker

      if false
        th = Thread.new(args){|a| pw_search_tasks(a) }
      else
        pw_search_tasks(args)
        th = nil
      end

      if conn = Pwrake.current_shell
        application.thread_loop(conn,self)
      else
        while true
          t = application.finish_queue.deq
          break if t==self
          #application.postprocess(t)   #        <---------
          #t.pw_enq_subsequents         #        <---------
        end
      end

      th.join if th
    end

    def pw_search_tasks(args)
      task_args = TaskArguments.new(arg_names, args)
      timer = Timer.new("search_task")
      h = application.pwrake_options['HALT_QUEUE_WHILE_SEARCH']
      application.task_queue.synchronize(h) do
	search_with_call_chain(self, task_args, InvocationChain::EMPTY)
      end
      timer.finish
    end

    def pw_invoke
      time_start = Time.now
      if shell = Pwrake.current_shell
        shell.current_task = self
        #host = shell.host
        #log_host(host)
      end

      @lock.synchronize do
        return if @already_invoked
        @already_invoked = true
      end
      pw_execute(@arg_data) if needed?
      if kind_of?(Rake::FileTask)
        application.postprocess(self) #        <---------
        @file_stat = File::Stat.new(name)
      end
      log_task(time_start)
      #pw_enq_subsequents2           #        <---------
      application.finish_queue.enq(self)
      shell.current_task = nil if shell
      pw_enq_subsequents3           #        <---------
    end

    def log_task(time_start)
      return if !application.task_logger
      time_end = Time.now
      row = [ @task_id, name,
        time_start, time_end, time_end-time_start,
        @prerequisites.join('|')
      ]

      if loc = suggest_location()
        row << loc.join('|')
      else
        row << ''
      end

      if shell = Pwrake.current_shell
        row.concat [shell.host, shell.id]
      else
        row.concat ['','']
      end

      row << ((@actions.empty?) ? 0 : 1)
      row << ((@executed) ? 1 : 0)

      if loc && !loc.empty? && shell && !@actions.empty?
        Pwrake.application.count( loc, shell.host )
      end

      if @file_stat
        row.concat [@file_stat.size, @file_stat.mtime, self.location.join('|')]
      else
        row.concat ['','','']
      end

      s = row.map do |x|
        if x.kind_of?(Time)
          Profiler.format_time(x)
        elsif x.kind_of?(String) && x!=''
          '"'+x+'"'
        else
          x.to_s
        end
      end.join(',')

      # task_id task_name start_time end_time elap_time preq preq_host
      # exec_host shell_id has_action executed file_size file_mtime file_host
      application.task_logger.print s+"\n"
    end


    # Execute the actions associated with this task.
    def pw_execute(args=nil)
      args ||= Rake::EMPTY_TASK_ARGS
      if application.options.dryrun
        Log.info "** Execute (dry run) #{name}"
        return
      end
      if application.options.trace
        Log.info "** Execute #{name}"
      end
      application.enhance_with_matching_rule(name) if @actions.empty?
      begin
        @actions.each do |act|
          case act.arity
          when 1
            act.call(self)
          else
            act.call(self, args)
        end
        end
      rescue Exception=>e
        if kind_of?(Rake::FileTask) && File.exist?(name)
          opt = application.pwrake_options['FAILED_TARGET']||"rename"
          case opt
          when /rename/i
            dst = name+"._fail_"
            ::FileUtils.mv(name,dst)
            msg = "Rename failed target file '#{name}' to '#{dst}'"
            Log.stderr_puts(msg)
          when /delete/i
            ::FileUtils.rm(name)
            msg = "Delete failed target file '#{name}'"
            Log.stderr_puts(msg)
          when /leave/i
          end
        end
        raise e
      end
      @executed = true if !@actions.empty?
    end

    def pw_enq_subsequents
      @lock.synchronize do
        @subsequents.each do |t|        # <<--- competition !!!
          t && t.check_and_enq(self.name)
        end
        @already_finished = true        # <<--- competition !!!
      end
    end

    def pw_enq_subsequents2
      @lock.synchronize do
        application.task_queue.synchronize(true) do
          @subsequents.each do |t|        # <<--- competition !!!
            t && t.check_and_enq(self.name)
          end
          @already_finished = true        # <<--- competition !!!
        end
      end
    end

    def pw_enq_subsequents3
      @lock.synchronize do
        #application.task_queue.synchronize(true) do
          @subsequents.each do |t|        # <<--- competition !!!
            if t && t.check_prereq_finished(self.name)
              #if t.actions.empty?
              #  #invoke_list.push(t)
              #  t.pw_invoke
              #else
                application.task_queue.enq(t)
              #end
            end
          end
          @already_finished = true        # <<--- competition !!!
        #end
      end
    end

    def check_prereq_finished(preq_name=nil)
      @unfinished_prereq.delete(preq_name)
      @unfinished_prereq.empty?
    end

    def check_and_enq(preq_name=nil)
      if check_prereq_finished(preq_name)
	Log.debug "--- check_and_enq enq name=#{self.name} "
        #if @actions.empty?
        #  return true
        #else
          application.task_queue.enq(self)
        #end
      end
      false
    end

    # Same as search, but explicitly pass a call chain to detect
    # circular dependencies.
    def search_with_call_chain(subseq, task_args, invocation_chain) # :nodoc:
      new_chain = InvocationChain.append(self, invocation_chain)
      @lock.synchronize do
        if application.options.trace
          Log.info "** Search #{name} #{format_search_flags}"
        end

        return true if @already_finished # <<--- competition !!!
        @subsequents ||= []
        @subsequents << subseq           # <<--- competition !!!

        if ! @already_searched
          @already_searched = true
          @arg_data = task_args
          if @prerequisites.empty?
            @task_id = application.task_id_counter
            @unfinished_prereq = {}
            #if @actions.empty?           # <--
            #  pw_invoke
            #else
              application.task_queue.enq(self)
            #end
          else
            search_prerequisites(task_args, new_chain)
          end
        end
        return false
      end
    rescue Exception => ex
      add_chain_to(ex, new_chain)
      raise ex
    end

    # Search all the prerequisites of a task.
    def search_prerequisites(task_args, invocation_chain) # :nodoc:
      @unfinished_prereq = @prerequisites.dup
      prerequisite_tasks.each { |prereq|
        #prereq_args = task_args.new_scope(prereq.arg_names) # in vain
        if prereq.search_with_call_chain(self, task_args, invocation_chain)
          @unfinished_prereq.delete(prereq.name)
        end
      }
      @task_id = application.task_id_counter
      check_and_enq
    end

    # Format the trace flags for display.
    def format_search_flags
      flags = []
      flags << "finished" if @already_finished
      flags << "first_time" unless @already_searched
      flags << "not_needed" unless needed?
      flags.empty? ? "" : "(" + flags.join(", ") + ")"
    end
    private :format_search_flags

    def file_size
      @file_stat ? @file_stat.size : 0
    end

    def suggest_location
      if @suggest_location.nil?
        @suggest_location = []
        if kind_of?(Rake::FileTask)
          loc_fsz = Hash.new(0)
          @prerequisites.each do |preq|
            t = application[preq]
            loc = t.location
            fsz = t.file_size
            if loc && fsz > 0
              loc.each do |h|
                loc_fsz[h] += fsz
              end
            end
          end
          if !loc_fsz.empty?
            half_max_fsz = loc_fsz.values.max / 2
            Log.debug "--- loc_fsz=#{loc_fsz.inspect} half_max_fsz=#{half_max_fsz}"
            loc_fsz.each do |h,sz|
              if sz > half_max_fsz
                @suggest_location << h
              end
            end
            #Log.debug "--- @suggest_location=#{@suggest_location.inspect}"
          end
        end
      end
      @suggest_location
    end

    def suggest_location2
      if kind_of?(Rake::FileTask) && preq_name = @prerequisites[0]
        application[preq_name].location
      end
    end

    def log_host(exec_host)
      # exec_host = Pwrake.current_shell.host
      if loc = suggest_location()
        Pwrake.application.count( loc, exec_host )
        if loc.include? exec_host
          compare = "=="
        else
          compare = "!="
        end
        Log.info "-- access to #{@prerequisites[0]}: file_host=#{loc.inspect} #{compare} exec_host=#{exec_host}"
      end
    end

  end

end # module Pwrake
