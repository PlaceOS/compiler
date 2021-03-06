require "exec_from"

module PlaceOS::Compiler
  class Error < Exception
    class Git < Error
      def self.from_result(command, result : ExecFrom::Result)
        new("`git #{command.join(' ')}` failed with #{result.output}")
      end
    end
  end

  class CommandFailure < Error
    getter exit_code : Int32

    def initialize(@exit_code = 1, message = nil)
      super(message || "git exited with code: #{@exit_code}")
    end

    def initialize(result : ExecFrom::Result)
      @exit_code = result.status.exit_code
      super("command exited with #{@exit_code}: #{result.output}")
    end
  end
end
