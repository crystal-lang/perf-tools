require "./common"

module PerfTools::FiberTrace
  # :nodoc:
  class_getter spawn_stack = {} of Fiber => Array(String)

  # :nodoc:
  class_getter yield_stack = {} of Fiber => Array(String)

  {% begin %}
    # :nodoc:
    # TODO: support
    STACK_DEPTH = {{ (env("FIBERTRACE_STACK_DEPTH") || "5").to_i }}

    # :nodoc:
    # TODO: support
    STACK_SKIP_NEW = {{ (env("FIBERTRACE_STACK_SKIP_NEW") || "4").to_i }}

    # :nodoc:
    # TODO: support
    STACK_SKIP_YIELD = {{ (env("FIBERTRACE_STACK_SKIP_YIELD") || "4").to_i }}
  {% end %}

  # Logs all existing fibers, aggregated by the call stacks at their creation
  # and last yield, to the given *io* as a Markdown table.
  #
  # Example output:
  #
  # ```text
  # | Count | Fibers | Spawn stack | Yield stack |
  # |------:|:-------|:------------|:------------|
  # | 1 | ` Signal Loop ` | ` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/signal.cr:60:5 in 'start_loop' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/signal.cr:163:5 in 'setup_default_handlers' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/kernel.cr:558:1 in '__crystal_main' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:129:5 in 'main_user_code' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:115:7 in 'main' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:141:3 in 'main' ` | ` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/scheduler.cr:50:5 in 'reschedule' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/evented.cr:128:5 in 'wait_readable' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/evented.cr:119:3 in 'wait_readable' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/evented.cr:59:9 in 'unbuffered_read' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/buffered.cr:261:5 in 'fill_buffer' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/buffered.cr:82:9 in 'read' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io.cr:540:7 in 'read_fully?' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io.cr:523:5 in 'read_fully' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/byte_format.cr:123:3 in 'decode' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/int.cr:781:5 in 'from_io' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io.cr:916:5 in 'read_bytes' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/signal.cr:62:17 in '->' `<br>` src/perf_tools/fiber_trace.cr:98:3 in 'run' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/fiber.cr:98:34 in '->' ` |
  # | 1 | ` Fiber Clean Loop ` | ` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/kernel.cr:558:1 in '__crystal_main' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:129:5 in 'main_user_code' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:115:7 in 'main' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:141:3 in 'main' ` | ` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/scheduler.cr:174:5 in 'sleep' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/scheduler.cr:58:5 in 'sleep' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/concurrent.cr:14:3 in 'sleep' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/kernel.cr:558:1 in '->' `<br>` src/perf_tools/fiber_trace.cr:98:3 in 'run' `<br>` /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/fiber.cr:98:34 in '->' ` |
  # ```
  def self.pretty_log_fibers(io : IO) : Nil
    # The top 3 spawn frames are:
    #
    # * the redefined `Fiber#initialize`
    # * `Fiber.new`
    # * the redefined `spawn`
    #
    # The top 4 yield frames are:
    #
    # * the redefined `Crystal::Scheduler#resume`
    # * `Crystal::Scheduler.resume`
    # * `Fiber#resume`
    # * `Crystal::Scheduler#reschedule`
    #
    # To reduce bloat we skip those frames when grouping the fiber records.
    # TODO: make these customizable using the constants above

    uniqs = spawn_stack
      .map { |fiber, stack| {fiber.name, stack, yield_stack[fiber]?} }
      .group_by { |_, s, y| {s[3..], y.try &.[4..]} }
      .transform_values(&.map { |fiber, _, _| fiber })
      .to_a
      .sort_by! { |(s, y), names| {-names.size, s, y || %w()} }

    io.puts "| Count | Fibers | Spawn stack | Yield stack |"
    io.puts "|------:|:-------|:------------|:------------|"
    uniqs.each do |(s, y), names|
      io << "| "
      io << names.size
      io << " | "
      names.compact.join(io, ' ') { |name| md_code_span(io, name) }
      io << " | "
      s.join(io, "<br>") { |frame| md_code_span(io, frame) }
      io << " | "
      if y
        y.join(io, "<br>") { |frame| md_code_span(io, frame) }
      else
        io << "*N/A*"
      end
      io << " |\n"
    end
  end

  private def self.md_code_span(io : IO, str : String) : Nil
    ticks = 0
    str.scan(/`+/) { |m| ticks = {ticks, m.size}.max }
    ticks.times { io << '`' }
    io << "` " << str << " `"
    ticks.times { io << '`' }
  end
end

class Fiber
  def initialize(@name : String? = nil, &@proc : ->)
    previous_def(name, &proc)
    PerfTools::FiberTrace.spawn_stack[self] = caller
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
    PerfTools::FiberTrace.yield_stack[@current] = caller
    previous_def
  end
end
