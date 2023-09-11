# This file defines a new function, `Fiber.print_stacks(IO)`, that writes a
# table of all fiber stacks to the given `IO`.
#
# The table includes the call stack up to the fiber's creation, as well as the
# call stack up to the fiber's last yield, if any. Fibers are grouped by their
# spawn / yield stacks and counted separately. The main fiber of each thread is
# not shown yet.

require "./common"

module PerfTools::FiberTrace
  # :nodoc:
  class_getter spawn_stack = {} of Fiber => Array(String)

  # :nodoc:
  class_getter yield_stack = {} of Fiber => Array(String)

  {% begin %}
    STACK_DEPTH = {{ (env("FIBERTRACE_STACK_DEPTH") || "5").to_i }}

    STACK_SKIP = {{ (env("FIBERTRACE_STACK_SKIP") || "4").to_i }}
  {% end %}

  def self.print_stacks(io : IO) : Nil
    # The top 3 spawn frames are:
    #
    # * the redefined `Fiber#initialize`
    # * `Fiber.new`
    # * the redefined `spawn`
    #
    # The top 4 yield framse are:
    #
    # * the redefined `Crystal::Scheduler#resume`
    # * `Crystal::Scheduler.resume`
    # * `Fiber#resume`
    # * `Crystal::Scheduler#reschedule`
    #
    # To reduce bloat we skip those frames when grouping the fiber records.

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
