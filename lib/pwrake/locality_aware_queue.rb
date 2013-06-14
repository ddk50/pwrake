module Pwrake

  module TaskAlgorithm
    def assigned
      @assigned ||= []
    end
  end


  class LocalityConditionVariable < ConditionVariable
    def signal(hints=nil)
      if hints.nil?
        super()
      elsif Array===hints
        Thread.handle_interrupt(StandardError => :on_blocking) do
          thread = nil
          @waiters_mutex.synchronize do
            @waiters.each do |t,v|
              if hints.include?(t[:hint])
                thread = t
                break
              end
            end
            if thread
              @waiters.delete(thread)
            else
              thread,_ = @waiters.shift
            end
          end
          Log.debug "--- LCV#signal: hints=#{hints.inspect} thread_to_run=#{thread.inspect} @waiters.size=#{@waiters.size}"
          begin
            thread.run if thread
          rescue ThreadError
            retry # t was already dead?
          end
        end
      else
        raise ArgumentError,"argument must be an Array"
      end
      self
    end

    def broadcast(hints=nil)
      if hints.nil?
        super()
      elsif Array===hints
        Thread.handle_interrupt(StandardError => :on_blocking) do
          threads = []
          @waiters_mutex.synchronize do
            hints.each do |h|
              @waiters.each do |t,v|
                if t[:hint] == h
                  threads << t
                  break
                end
              end
            end
            threads.each do |t|
              @waiters.delete(t)
            end
          end
          Log.debug "--- LCV#broadcast: hints=#{hints.inspect} threads_to_run=#{threads.inspect} @waiters.size=#{@waiters.size}"
          threads.each do |t|
            begin
              t.run
            rescue ThreadError
            end
          end
        end
      else
        raise ArgumentError,"argument must be an Array"
      end
      self
    end
  end


  class LocalityAwareQueue < TaskQueue

    class Throughput

      def initialize(list=nil)
        @interdomain_list = {}
        @interhost_list = {}
        if list
          values = []
          list.each do |x,y,v|
            hash_x = (@interdomain_list[x] ||= {})
            hash_x[y] = n = v.to_f
            values << n
          end
          @min_value = values.min
        else
          @min_value = 1
        end
      end

      def interdomain(x,y)
        hash_x = (@interdomain_list[x] ||= {})
        if v = hash_x[y]
          return v
        elsif v = (@interdomain_list[y] || {})[x]
          hash_x[y] = v
        else
          if x == y
            hash_x[y] = 1
          else
            hash_x[y] = 0.1
          end
        end
        hash_x[y]
      end

      def interhost(x,y)
        return @min_value if !x
        hash_x = (@interhost_list[x] ||= {})
        if v = hash_x[y]
          return v
        elsif v = (@interhost_list[y] || {})[x]
          hash_x[y] = v
        else
          x_short, x_domain = parse_hostname(x)
          y_short, y_domain = parse_hostname(y)
          v = interdomain(x_domain,y_domain)
          hash_x[y] = v
        end
        hash_x[y]
      end

      def parse_hostname(host)
        /^([^.]*)\.?(.*)$/ =~ host
        [$1,$2]
      end

    end # class Throughput


    def initialize(hosts,opt={})
      super(opt)
      @cv = LocalityConditionVariable.new
      @hosts = hosts
      @throughput = Throughput.new
      @size = 0
      @q2 = {}
      @hosts.each{|h| @q2[h]=@array_class.new}
      @q2_remote = @array_class.new
      @q2_nohint = @array_class.new
      @enable_steal = !opt['disable_steal']
      @time_prev = Time.now
    end

    attr_reader :size


    def enq_impl(t,hints=nil)
      if hints.nil? || hints.empty?
        @q2_nohint.push(t)
      else
        stored = false
        hints.each do |h|
          if q = @q2[h]
            t.assigned.push(h)
            q.push(t)
            stored = true
          end
        end
        if !stored
          @q2_remote.push(t)
        end
      end
      @size += 1
    end


    def deq_impl(host,n)
      if !@q2_nohint.empty?
        t = @q2_nohint.shift
        Log.info "-- deq_nohint n=#{n} task=#{t.name} host=#{host}"
        Log.debug "--- deq_impl\n#{inspect_q}"
        return t
      end

      if t = deq_locate(host)
        Log.info "-- deq_locate n=#{n} task=#{t.name} host=#{host}"
        Log.debug "--- deq_impl\n#{inspect_q}"
        return t
      end

      if !@q2_remote.empty?
        t = @q2_remote.shift
        Log.info "-- deq_remote n=#{n} task=#{t.name} host=#{host}"
        Log.debug "--- deq_impl\n#{inspect_q}"
        return t
      end

      if @enable_steal && n > 0
        if t = deq_steal(host)
          Log.info "-- deq_steal n=#{n} task=#{t.name} host=#{host}"
          Log.debug "--- deq_impl\n#{inspect_q}"
          return t
        end
      end

      #hints = []
      #@q2.each do |h,q|
      #  if h && !q.empty?
      #    hints << h
      #  end
      #end
      #@cv.broadcast(hints)

      #@cv.wait(@mutex)

      m = 0.05*(2**([n,10].min))
      @cv.wait(@mutex,m)
      nil
    end


    def deq_locate(host)
      q = @q2[host]
      if q && !q.empty?
        t = q.shift
        t.assigned.each{|x| @q2[x].delete_if{|x| t.equal? x}}
        @size -= 1
        return t
      else
        nil
      end
    end

    def deq_steal(host)
      # select a task based on many and close
      max_host = nil
      max_num  = 0
      @q2.each do |h,a|
        if !a.empty?
          d = a.size
          if d > max_num
            max_host = h
            max_num  = d
          end
        end
      end
      Log.info "-- deq_steal max_host=#{max_host} max_num=#{max_num}"
      deq_locate(max_host)
    end

    def inspect_q
      s = ""
      b = proc{|h,q|
        s += " #{h}: size=#{q.size} "
        case q.size
        when 0
          s += "[]\n"
        when 1
          s += "[#{q[0].name}]\n"
        else
          s += "[#{q[0].name},..]\n"
        end
      }
      b.call("nohint",@q2_nohint)
      @q2.each(&b)
      b.call("remote",@q2_remote)
      s
    end

    def size
      @size
    end

    def clear
      @q2_nohint.clear
      @q2_remote.clear
      @q2.each{|h,q| q.clear}
    end

    def empty?
      @q2_nohint.empty? &&
        @q2_remote.empty? &&
        @q2.all?{|h,q| q.empty?}
    end

    def finish
      super
    end

  end
end
