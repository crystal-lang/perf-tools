require "./common"

# In-memory tracking of all existing fibers in the running program.
module PerfTools::FiberTrace
  # :nodoc:
  class_getter spawn_stack = {} of Fiber => Array(Void*)

  # :nodoc:
  class_getter yield_stack = {} of Fiber => Array(Void*)

  {% begin %}
    # The maximum number of stack frames shown for `FiberTrace.log_fibers` and
    # `FiberTrace.pretty_log_fibers`.
    #
    # Configurable at run time using the `FIBERTRACE_STACK_DEPTH` environment
    # variable.
    STACK_DEPTH = ENV["FIBERTRACE_STACK_DEPTH"]?.try(&.to_i) || 5

    # The number of stack frames to skip from the fiber creation call stacks for
    # `FiberTrace.log_fibers` and `FiberTrace.pretty_log_fibers`. There is
    # usually no reason to alter this.
    #
    # Configurable at run time using the `FIBERTRACE_STACK_SKIP_SPAWN`
    # environment variable.
    STACK_SKIP_SPAWN = ENV["FIBERTRACE_STACK_SKIP_SPAWN"]?.try(&.to_i) || 4

    # The number of stack frames to skip from the fiber yield call stacks for
    # `FiberTrace.log_fibers` and `FiberTrace.pretty_log_fibers`. There is
    # usually no reason to alter this.
    #
    # Configurable at run time using the `FIBERTRACE_STACK_SKIP_YIELD`
    # environment variable.
    STACK_SKIP_YIELD = ENV["FIBERTRACE_STACK_SKIP_YIELD"]?.try(&.to_i) || 5
  {% end %}

  # Logs all existing fibers, plus the call stacks at their creation
  # and last yield, to the given *io*.
  #
  # The behavior of this method can be controlled by the `STACK_DEPTH`,
  # `STACK_SKIP_SPAWN`, and `STACK_SKIP_YIELD` constants.
  #
  # The first line contains the number of fibers. For each fiber, the first line
  # is the fiber's name (may be empty), and the second line is the number of
  # frames on the fiber's creation stack, followed by the stack itself, one line
  # per frame. After that, the yield stack follows, except that it may contain 0
  # frames. Example output:
  #
  # ```
  # require "perf_tools/fiber_trace"
  #
  # spawn { sleep }
  # sleep 1
  # PerfTools::FiberTrace.log_fibers(STDOUT)
  # ```
  #
  # ```text
  # 3
  # Fiber Clean Loop
  # 4
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/kernel.cr:558:1 in '__crystal_main'
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:129:5 in 'main_user_code'
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:115:7 in 'main'
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:141:3 in 'main'
  # 5
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/scheduler.cr:174:5 in 'sleep'
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/scheduler.cr:58:5 in 'sleep'
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/concurrent.cr:14:3 in 'sleep'
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/kernel.cr:558:1 in '->'
  # src/perf_tools/fiber_trace.cr:184:3 in 'run'
  # Signal Loop
  # 5
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/signal.cr:60:5 in 'start_loop'
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/signal.cr:163:5 in 'setup_default_handlers'
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/kernel.cr:558:1 in '__crystal_main'
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:129:5 in 'main_user_code'
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:115:7 in 'main'
  # 5
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/scheduler.cr:50:5 in 'reschedule'
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/evented.cr:128:5 in 'wait_readable'
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/evented.cr:119:3 in 'wait_readable'
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/evented.cr:59:9 in 'unbuffered_read'
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/buffered.cr:261:5 in 'fill_buffer'
  #
  # 4
  # test.cr:4:1 in '__crystal_main'
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:129:5 in 'main_user_code'
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:115:7 in 'main'
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:141:3 in 'main'
  # 5
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/scheduler.cr:50:5 in 'reschedule'
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/concurrent.cr:29:3 in 'sleep'
  # test.cr:3:9 in '->'
  # src/perf_tools/fiber_trace.cr:184:3 in 'run'
  # /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/fiber.cr:98:34 in '->'
  # ```
  #
  # NOTE: The main fiber of each thread is not shown.
  def self.log_fibers(io : IO) : Nil
    io << spawn_stack.size << '\n'
    spawn_stack.each do |fiber, stack|
      io << fiber.name << '\n'

      s = Exception::CallStack.new(__callstack: stack).printable_backtrace
      io << s.size << '\n'
      s.each { |frame| io << frame << '\n' }

      if yield_stack = self.yield_stack[fiber]?
        y = Exception::CallStack.new(__callstack: yield_stack).printable_backtrace
        io << y.size << '\n'
        y.each { |frame| io << frame << '\n' }
      else
        io << '0' << '\n'
      end
    end
  end

  # Logs all existing fibers, aggregated by the call stacks at their creation
  # and last yield, to the given *io* as a Markdown table.
  #
  # The behavior of this method can be controlled by the `STACK_DEPTH`,
  # `STACK_SKIP_SPAWN`, and `STACK_SKIP_YIELD` constants.
  #
  # Example output:
  #
  # ```
  # require "perf_tools/fiber_trace"
  #
  # spawn { sleep }
  # sleep 1
  # PerfTools::FiberTrace.pretty_log_fibers(STDOUT)
  # ```
  #
  # ```text
  # | Count | Fibers | Spawn stack | Yield stack |
  # |------:|:-------|:------------|:------------|
  # | 1 | ` Fiber Clean Loop ` | ` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/kernel.cr:558:1 in '__crystal_main' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:129:5 in 'main_user_code' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:115:7 in 'main' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:141:3 in 'main' ` | ` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/scheduler.cr:174:5 in 'sleep' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/scheduler.cr:58:5 in 'sleep' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/concurrent.cr:14:3 in 'sleep' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/kernel.cr:558:1 in '->' `<br>` /Users/quinton/crystal/perf-tools/src/perf_tools/fiber_trace.cr:172:3 in 'run' ` |
  # | 1 |  | ` test.cr:4:1 in '__crystal_main' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:129:5 in 'main_user_code' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:115:7 in 'main' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:141:3 in 'main' ` | ` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/scheduler.cr:50:5 in 'reschedule' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/concurrent.cr:29:3 in 'sleep' `<br>` test.cr:3:9 in '->' `<br>` /Users/quinton/crystal/perf-tools/src/perf_tools/fiber_trace.cr:172:3 in 'run' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/fiber.cr:98:34 in '->' ` |
  # | 1 | ` Signal Loop ` | ` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/signal.cr:60:5 in 'start_loop' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/signal.cr:163:5 in 'setup_default_handlers' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/kernel.cr:558:1 in '__crystal_main' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:129:5 in 'main_user_code' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:115:7 in 'main' ` | ` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/scheduler.cr:50:5 in 'reschedule' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/evented.cr:128:5 in 'wait_readable' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/evented.cr:119:3 in 'wait_readable' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/evented.cr:59:9 in 'unbuffered_read' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/buffered.cr:261:5 in 'fill_buffer' ` |
  # ```
  #
  # NOTE: The main fiber of each thread is not shown.
  def self.pretty_log_fibers(io : IO) : Nil
    uniqs = spawn_stack
      .map { |fiber, stack| {fiber.name, stack, yield_stack[fiber]?} }
      .group_by { |_, s, y| {s, y} }
      .transform_values(&.map { |fiber, _, _| fiber })
      .to_a
      .sort_by! { |(s, y), names| {-names.size, s, y || Array(Void*).new} }

    io.puts "| Count | Fibers | Spawn stack | Yield stack |"
    io.puts "|------:|:-------|:------------|:------------|"
    uniqs.each do |(s, y), names|
      s = Exception::CallStack.new(__callstack: s).printable_backtrace
      y = y.try { |y| Exception::CallStack.new(__callstack: y).printable_backtrace }

      io << "| "
      io << names.size
      io << " | "
      names.compact.join(io, ' ') { |name| PerfTools.md_code_span(io, name) }
      io << " | "
      s.join(io, "<br>") { |frame| PerfTools.md_code_span(io, frame) }
      io << " | "
      if y
        y.join(io, "<br>") { |frame| PerfTools.md_code_span(io, frame) }
      else
        io << "*N/A*"
      end
      io << " |\n"
    end
  end
end

class Fiber
  def initialize(@name : String? = nil, &@proc : ->)
    previous_def(name, &proc)

    stack = Array.new(PerfTools::FiberTrace::STACK_DEPTH + PerfTools::FiberTrace::STACK_SKIP_SPAWN, Pointer(Void).null)
    Exception::CallStack.unwind_to(Slice.new(stack.to_unsafe, stack.size))
    stack.truncate(PerfTools::FiberTrace::STACK_SKIP_SPAWN..)
    while stack.last? == Pointer(Void).null
      stack.pop
    end
    PerfTools::FiberTrace.spawn_stack[self] = stack
  end

  def self.inactive(fiber : Fiber)
    PerfTools::FiberTrace.spawn_stack.delete(fiber)
    PerfTools::FiberTrace.yield_stack.delete(fiber)
    previous_def
  end

  # crystal-lang/crystal#13701
  {% if compare_versions(Crystal::VERSION, "1.10.0") < 0 %}
    def run
      GC.unlock_read
      @proc.call
    rescue ex
      if name = @name
        STDERR.print "Unhandled exception in spawn(name: #{name}): "
      else
        STDERR.print "Unhandled exception in spawn: "
      end
      ex.inspect_with_backtrace(STDERR)
      STDERR.flush
    ensure
      {% if flag?(:preview_mt) %}
        Crystal::Scheduler.enqueue_free_stack @stack
      {% elsif flag?(:interpreted) %}
        # For interpreted mode we don't need a new stack, the stack is held by the interpreter
      {% else %}
        Fiber.stack_pool.release(@stack)
      {% end %}

      # Remove the current fiber from the linked list
      Fiber.inactive(self)

      # Delete the resume event if it was used by `yield` or `sleep`
      @resume_event.try &.free
      @timeout_event.try &.free
      @timeout_select_action = nil

      @alive = false
      Crystal::Scheduler.reschedule
    end
  {% end %}
end

class Crystal::Scheduler
  protected def resume(fiber : Fiber) : Nil
    stack = Array.new(PerfTools::FiberTrace::STACK_DEPTH + PerfTools::FiberTrace::STACK_SKIP_YIELD, Pointer(Void).null)
    Exception::CallStack.unwind_to(Slice.new(stack.to_unsafe, stack.size))
    stack.truncate(PerfTools::FiberTrace::STACK_SKIP_YIELD..)
    while stack.last? == Pointer(Void).null
      stack.pop
    end
    PerfTools::FiberTrace.yield_stack[@current] = stack

    previous_def
  end
end
