module Haconiwa
  class Provision
    def initialize
      @ops = []
    end
    attr_accessor :root, :extra_bind # TODO
    attr_reader   :ops

    class ProvisionOps
      def initialize(strategy, name, body)
        @strategy = strategy
        @name = name
        @body = body
      end
      attr_reader :strategy, :name, :body
    end

    def run_shell(shell, options={})
      name = options.delete(:name)
      name ||= "shell-#{ops.size + 1}"
      ops << ProvisionOps.new("shell", name, shell)
    end

    def provision!(r)
      self.root = Pathname.new(r.to_s)

      p = self
      log "Start provisioning..."
      pid = Process.fork do
        p.chroot_into(p.root)

        p.ops.each do |op|
          case strategy = op.strategy
          when "shell"
            p.provision_with_shell(op)
          else
            raise "Unsupported: #{strategy}"
          end
        end
      end
      pid, s = *Process.waitpid2(pid)

      if s.success?
        log "Success!"
        return true
      else
        log "Provisioning failed: #{s.inspect}!"
        return false
      end
    end

    def provision_with_shell(op)
      cmd = RunCmd.new("provison.#{op.name}")

      log("Running provisioning with shell script...")
      cmd.run_with_input("/bin/bash -xe", op.body)
    end

    def chroot_into(root)
      m = ::Mount.new
      ::Namespace.unshare ::Namespace::CLONE_NEWNS

      m.make_private "/"
      Dir.chdir root
      Dir.chroot root
      m.mount "proc",     "/proc", type: "proc"
      m.mount "devtmpfs", "/dev",  type: "devtmpfs"
      m.mount "sysfs",    "/sys",  type: "sysfs"
      m.mount "tmpfs",    "/tmp",  type: "tmpfs"
    end

    private
    def log(msg)
      $stderr.puts msg.green
    end
  end
end
