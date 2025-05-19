require "./common"
require "../core_ext/fiber"

module PerfTools::SchedulerTrace
  {% if flag?(:unix) %}
    # Installs a signal handler to call `.print_runtime_status` on demand.
    #
    # You can use `Signal::USR1` or another `Signal`. You must be careful not to
    # reuse the signals used by the GC to stop or resume the world (see
    # `GC.sig_suspend` and `GC.sig_resume`) that uses different signals
    # depending on the target and configuration.
    #
    # Set *details* to false to skip individual fiber details.
    def self.on(signal : Signal, details : Bool = true) : Nil
      # not using Signal#trap so the signal will be handled directly instead
      # of through the event loop that may have to wait (or be blocked in
      # the worst case):
      action = LibC::Sigaction.new
      action.sa_flags = LibC::SA_RESTART

      # we can't pass a closure to a C function, so we use different handlers:
      action.sa_sigaction =
        if details
          LibC::SigactionHandlerT.new { |_, _, _| print_runtime_status(details: true) }
        else
          LibC::SigactionHandlerT.new { |_, _, _| print_runtime_status(details: false) }
        end

      LibC.sigemptyset(pointerof(action.@sa_mask))
      LibC.sigaction(signal, pointerof(action), nil)
    end
  {% end %}

  # Starts a thread that will call `.print_runtime_status` on every *interval*
  # until the program terminates.
  #
  # Set *details* to true to print individual fiber details.
  def self.every(interval : Time::Span, details = false) : Nil
    Thread.new("PERF-TOOLS") do
      loop do
        Thread.sleep(interval)
        print_runtime_status(details)
      end
    end
  end

  # Stops the world, prints the status of all runtime schedulers to the standard
  # error, then resumes the world.
  #
  # Set `details` to true to print individual fiber details.
  def self.print_runtime_status(details = false) : Nil
    Thread.stop_world

    Crystal::System.print_error("sched.details time=%u\n", Crystal::System::Time.ticks)

    Fiber::ExecutionContext.unsafe_each do |execution_context|
      print_runtime_status(execution_context, details)
    end

    Thread.start_world
  end

  private def self.print_runtime_status(execution_context : Fiber::ExecutionContext::MultiThreaded, details = false) : Nil
    Crystal::System.print_error("%s name=%s global_queue.size=%d\n",
      execution_context.class.name,
      execution_context.name,
      execution_context.@global_queue.size)

    execution_context.@threads.each do |thread|
      print_runtime_status(thread, details)
    end

    return unless details

    Fiber.unsafe_each do |fiber|
      next unless fiber.execution_context? == execution_context
      next if execution_context.@threads.any? { |thread| thread.current_fiber? == fiber }
      print_runtime_status(fiber)
    end
  end

  private def self.print_runtime_status(execution_context : Fiber::ExecutionContext::SingleThreaded, details = false) : Nil
    Crystal::System.print_error("%s name=%s global_queue.size=%d\n",
      execution_context.class.name,
      execution_context.name,
      execution_context.@global_queue.size)

    print_runtime_status(execution_context.@thread, details)

    return unless details

    Fiber.unsafe_each do |fiber|
      next unless fiber.execution_context? == execution_context
      next if execution_context.@thread.current_fiber? == fiber
      print_runtime_status(fiber)
    end
  end

  private def self.print_runtime_status(execution_context : Fiber::ExecutionContext::Isolated, details = false) : Nil
    Crystal::System.print_error("%s name=%s\n",
      execution_context.class.name,
      execution_context.name)

    print_runtime_status(execution_context.@thread, details = false)
  end

  private def self.print_runtime_status(thread : Thread, details = false) : Nil
    thread_handle =
      {% if flag?(:linux) %}
        Pointer(Void).new(thread.@system_handle)
      {% else %}
        thread.@system_handle
      {% end %}

    case scheduler = thread.scheduler?
    when Fiber::ExecutionContext::MultiThreaded::Scheduler
      Crystal::System.print_error("  Scheduler name=%s thread=%p local_queue.size=%u status=%s\n",
        scheduler.name,
        thread_handle,
        scheduler.@runnables.size,
        scheduler.status)
    when Fiber::ExecutionContext::SingleThreaded
      Crystal::System.print_error("  Scheduler name=%s thread=%p local_queue.size=%u status=%s\n",
        scheduler.name,
        thread_handle,
        scheduler.@runnables.size,
        scheduler.status)
    when Fiber::ExecutionContext::Isolated
      Crystal::System.print_error("  Scheduler name=%s thread=%p status=%s\n",
        scheduler.name,
        thread_handle,
        scheduler.status)
    end

    return unless details

    if fiber = thread.current_fiber?
      Crystal::System.print_error("    Fiber %p name=%s status=running\n", fiber.as(Void*), fiber.name)
    end
  end

  private def self.print_runtime_status(fiber : Fiber) : Nil
    Crystal::System.print_error("  Fiber %p name=%s status=%s\n", fiber.as(Void*), fiber.name, fiber.status.to_s)
  end
end
