module Haconiwa
  class WaitLoop
    def initialize(wait_interval=5)
      @mainloop = FiberedWorker::MainLoop.new(interval: wait_interval)
      @wait_interval = wait_interval
    end
    attr_accessor :mainloop, :wait_interval

    def register_hooks(base)
      base.async_hooks.each do |hook|
        hook.set_signal!
        blk = hook.proc
        @mainloop.register_timer(hook.signal, hook.timing, hook.interval) do
          ::Haconiwa::Logger.warning("Async hook starting...")
          begin
            blk.call(base)
          rescue => e
            ::Haconiwa::Logger.warning("Async hook failed: #{e.class}, #{e.message}")
          end
        end
      end

      base.cgroup_hooks.each do |cghook|
        cghook.register!(base)
        blk = cghook.proc
        @mainloop.register_fd(cghook.fileno) do |_dummy|
          ::Haconiwa::Logger.warning("Cgroup hook[#{cghook.type}] starting...")
          begin
            blk.call(base)
          rescue => e
            ::Haconiwa::Logger.warning("Async hook[#{cghook.type}] failed: #{e.class}, #{e.message}")
          end
        end
      end
    end

    def register_sighandlers(base, runner)
      # Registers cleanup handler when unintended death
      [:SIGTERM, :SIGINT, :SIGPIPE].each do |sig|
        @mainloop.register_handler(sig, true) do
          unless base.cleaned
            ::Haconiwa::Logger.warning "Supervisor received unintended kill. Cleanup..."
            runner.cleanup_supervisor(base)
          end
          Process.kill :TERM, base.pid
          exit 127
        end
      end

      # Terminal uses SIGHUP; reload is enabled only in daemon mode
      if base.daemon? && !base.reloadable_attr.empty?
        # Registers reload handler
        b1 = base.cgroup(:v1).defblock
        b2 = base.cgroup(:v2).defblock
        r1 = base.resource.defblock

        @mainloop.register_handler(:SIGHUP, false) do
          begin
            newcg = Haconiwa::CGroup.new
            Haconiwa::Logger.info "Accepted reload: PID=#{base.pid}"
            b1.call(newcg) if b1
            newcg2 = Haconiwa::CGroupV2.new
            b2.call(newcg2) if b2
            newres = Haconiwa::Resource.new
            r1.call(newres) if r1

            base.reload(newcg, newcg2, newres)
          rescue Exception => e
            Haconiwa::Logger.warning "Reload failed: #{e.class}, #{e.message}"
            e.backtrace.each{|l| Haconiwa::Logger.warning "    #{l}" }
          end
        end
      end
    end

    def register_custom_sighandlers(base, handlers)
      handlers.each do |sig, callback|
        @mainloop.register_handler(sig, false) do
          callback.call(base)
        end
      end
    end

    def run_and_wait(pid)
      @mainloop.pid = pid
      p, s = *(@mainloop.run)
      Haconiwa::Logger.puts "Container[Host PID=#{p}] finished: #{s.inspect}"
      return [p, s]
    end

    class TimerHook
      def self.signal_pool
        @__signal_pool ||= []
      end

      def initialize(timing={}, &b)
        @timing = if s = timing[:msec]
                    s
                  elsif s = timing[:sec]
                    s * 1000
                  elsif s = timing[:min]
                    s * 1000 * 60
                  elsif s = timing[:hour]
                    s * 1000 * 60 * 60
                  else
                    raise(ArgumentError, "Invalid option: #{timing.inspect}")
                  end
        @interval = timing[:interval_msec] || 0 # TODO: other time scales
        @proc = b
        @id = UUID.secure_uuid
        @signal = nil
      end
      attr_reader :timing, :interval, :proc, :id, :signal

      # This method has a race problem, should be called serially
      def set_signal!
        idx = 0
        while !signal do
          if TimerHook.signal_pool.include?(:"SIGRT#{idx}")
            idx += 1
          else
            @signal = :"SIGRT#{idx}"
            TimerHook.signal_pool << @signal
          end
        end
      end
    end

    class CGroupHook
      VALID_TYPES = %w(memory_pressure oom).freeze

      def initialize(opt={}, &b)
        @type = opt[:type]
        unless VALID_TYPES.include?(@type.to_s)
          raise "Invalid hook type: #{@type}"
        end
        @level = opt[:level] || "critical"
        @proc = b
      end
      attr_reader :type, :level, :proc

      def register!(base)
        make_eventfd
        cfd = open_cgroup_file(base)
        write_to_control(base, @efd.fd, cfd.fileno)
        @efd
      end

      def fileno
        @efd && @efd.fd
      end
      alias fd fileno

      private
      def make_eventfd
        @efd = ::Eventfd.new(0, 0) # TODO: define Eventfd::EFD_NONBLOCK
      end

      def open_cgroup_file(base)
        File.open("/sys/fs/cgroup/memory/#{base.name}/memory.pressure_level", "r")
      end

      def write_to_control(base, efd, cfd)
        f = File.open("/sys/fs/cgroup/memory/#{base.name}/cgroup.event_control", "w")
        f.write "#{efd} #{cfd} #{@level}"
        f.close
      end
    end
  end
end
