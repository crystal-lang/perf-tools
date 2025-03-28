require "./common"

# In-memory tracking of all existing fibers in the running program.
module PerfTools::FiberTrace
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
  def self.log_fibers(io : IO) : Nil
    fibers = [] of Fiber
    Fiber.each { |fiber| fibers << fiber }

    io << fibers.size << '\n'

    fibers.each do |fiber|
      io << fiber.name << '\n'

      s = Exception::CallStack.__decode_backtrace(fiber.__spawn_stack)
      io << s.size << '\n'
      s.each { |frame| io << frame << '\n' }

      y = Exception::CallStack.__decode_backtrace(fiber.__yield_stack)
      io << y.size << '\n'
      y.each { |frame| io << frame << '\n' }
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
  def self.pretty_log_fibers(io : IO) : Nil
    fibers = [] of Fiber
    Fiber.each { |fiber| fibers << fiber }

    uniqs = fibers
      .map { |fiber| {fiber.name, fiber.__spawn_stack, fiber.__yield_stack} }
      .group_by { |_, s, y| {s, y} }
      .transform_values(&.map { |fiber, _, _| fiber })
      .to_a
      .sort_by! { |(s, y), names| {-names.size, s, y} }

    io.puts "| Count | Fibers | Spawn stack | Yield stack |"
    io.puts "|------:|:-------|:------------|:------------|"
    uniqs.each do |(s, y), names|
      io << "| "
      io << names.size
      io << " | "
      names.compact.join(io, ' ') { |name| PerfTools.md_code_span(io, name) }
      io << " | "
      Exception::CallStack.__decode_backtrace(s).join(io, "<br>") do |frame|
        PerfTools.md_code_span(io, frame)
      end
      io << " | "
      if y.size > 0
        Exception::CallStack.__decode_backtrace(y).join(io, "<br>") do |frame|
          PerfTools.md_code_span(io, frame)
        end
      else
        io << "*N/A*"
      end
      io << " |\n"
    end
  end

  # :nodoc:
  def self.caller_stack(skip, depth = PerfTools::FiberTrace::STACK_DEPTH)
    size = skip + depth

    stack = Array(Void*).new(size, Pointer(Void).null)
    slice = Slice(Void*).new(stack.to_unsafe, size)
    Exception::CallStack.unwind_to(slice)

    while stack.last?.try(&.null?)
      stack.pop
    end

    stack
  end

  # :nodoc:
  #
  # returns a slice view into the stack array, avoids allocating a new array,
  # returns an empty slice if array is nil.
  def self.stack_array_to_slice(stack, skip)
    if stack
      skip = PerfTools::FiberTrace::STACK_SKIP_YIELD
      Slice.new(stack.to_unsafe + skip, stack.size - skip)
    else
      Slice.new(Pointer(Void*).null, 0)
    end
  end
end

class Fiber
  # the stacks could be saved as slices instead of arrays but then we'd have two
  # writes to write the slice pointer and the slice size instead of a single
  # pointer write for the array (the buffer pointer and size are on the array
  # object); we could always allocate slices of DEPTH+SKIP size but we hit
  # recursion issues with crystal/once (fiber.current -> access constant ->
  # crystal/once -> fiber.current)
  @__spawn_stack : Array(Void*)?
  @__yield_stack : Array(Void*)?

  {% begin %}
  def initialize(
    name : String?,
    {% if Fiber.has_constant?(:Stack) %}stack : Stack,{% end %}
    {% if flag?(:execution_context) %}execution_context : ExecutionContext = ExecutionContext.current,{% end %}
    &proc : ->
  )
    @__spawn_stack = PerfTools::FiberTrace.caller_stack(PerfTools::FiberTrace::STACK_SKIP_SPAWN)
    previous_def(
      name,
      {% if Fiber.has_constant?(:Stack) %}stack,{% end %}
      {% if flag?(:execution_context) %}execution_context,{% end %}
      &proc
    )
  end
  {% end %}

  def __spawn_stack : Slice(Void*)
    PerfTools::FiberTrace.stack_array_to_slice(@__spawn_stack, PerfTools::FiberTrace::STACK_SKIP_SPAWN)
  end

  def __yield_stack : Slice(Void*)
    PerfTools::FiberTrace.stack_array_to_slice(@__yield_stack, PerfTools::FiberTrace::STACK_SKIP_YIELD)
  end

  def __yield_stack=(@__yield_stack)
  end
end

class Crystal::Scheduler
  protected def resume(fiber : Fiber) : Nil
    current_fiber = {% if Crystal::Scheduler.instance_vars.any? { |x| x.name == :thread.id } %}
                      # crystal >= 1.13
                      @thread.current_fiber
                    {% else %}
                      @current
                    {% end %}
    current_fiber.__yield_stack = PerfTools::FiberTrace.caller_stack(PerfTools::FiberTrace::STACK_SKIP_YIELD)
    previous_def
  end
end
