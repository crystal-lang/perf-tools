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
      load_debug_info if details

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
    load_debug_info if details

    Thread.new("PERF-TOOLS") do
      loop do
        Thread.sleep(interval)
        print_runtime_status(details)
      end
    end
  end

  @[NoInline]
  private def self.load_debug_info
    if Fiber.current.responds_to?(:__yield_stack)
      # load debug info + initialize globals (may need to allocate)
      caller
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

  private def self.print_runtime_status(execution_context : Fiber::ExecutionContext::Parallel, details = false) : Nil
    Crystal::System.print_error("%s name=%s global_queue.size=%d\n",
      execution_context.class.name,
      execution_context.name,
      execution_context.@global_queue.size)

    execution_context.@schedulers.each do |scheduler|
      next unless thread = scheduler.@thread

      Crystal::System.print_error("  Scheduler name=%s thread=%p local_queue.size=%u status=%s\n",
        scheduler.name,
        thread_handle(scheduler),
        scheduler.@runnables.size,
        scheduler.status)

      next unless details

      if fiber = thread.current_fiber?
        Crystal::System.print_error "  "
        print_runtime_status(fiber)
      end
    end

    return unless details

    Fiber.unsafe_each do |fiber|
      print_runtime_status(fiber) if fiber.execution_context? == execution_context
    end
  end

  private def self.print_runtime_status(execution_context : Fiber::ExecutionContext::Isolated, details = false) : Nil
    Crystal::System.print_error("%s name=%s\n",
      execution_context.class.name,
      execution_context.name)

    Crystal::System.print_error("  Scheduler name=%s thread=%p status=%s\n",
      execution_context.name,
      thread_handle(execution_context),
      execution_context.status)

    return unless details

    Crystal::System.print_error "  "
    print_runtime_status(execution_context.@main_fiber)
  end

  private def self.print_runtime_status(fiber : Fiber) : Nil
    Crystal::System.print_error("  Fiber %p name=%s status=%s\n", fiber.as(Void*), fiber.name, fiber.status.to_s)

    return unless fiber.responds_to?(:__yield_stack)
    return if fiber.status == "running"

    fiber.__yield_stack.each do |ip|
      Crystal::System.print_error("    ")
      Exception::CallStack.__perftools_print_frame_location(ip)
      Crystal::System.print_error("\n")
    end
  end

  private def self.thread_handle(scheduler)
    if thread = scheduler.@thread
      {% if flag?(:linux) %}
        Pointer(Void).new(thread.@system_handle)
      {% else %}
        thread.@system_handle
      {% end %}
    else
      Pointer(Void).null
    end
  end
end
