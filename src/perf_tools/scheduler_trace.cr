require "./common"

module PerfTools::SchedulerTrace
  {% if flag?(:unix) %}
    # Installs a signal handler to call `.print_runtime_status` on demand.
    #
    # Uses `SIGUSR1` by default but you may configure another signal, for
    # example `LibC::SIGRTMIN + 7`. You may also register multiple signals, one
    # with fiber detail and the another without for example.
    def self.on(signal : Int32 = Signal::USR1.value, details = false) : Nil
      # not using Signal#trap so the signal will be handled directly instead
      # of through the event loop that may have to wait (or be blocked in
      # the worst case):
      action = LibC::Sigaction.new
      action.sa_flags = LibC::SA_RESTART
      action.sa_sigaction = LibC::SigactionHandlerT.new do |_, _, _|
        print_runtime_status(details)
      end
      LibC.sigemptyset(pointerof(action.@sa_mask))
      LibC.sigaction(signal, pointerof(action), nil)
    end
  {% end %}

  # Starts a thread that will call `.print_runtime_status` every *time* until
  # the program terminates.
  def self.every(time : Time::Span, details = false) : Nil
    Thread.new("PerfToolsSched") do
      loop do
        Thread.sleep(time)
        print_runtime_status(details)
      end
    end
  end

  # Stops the world, prints the status of all runtime schedulers, then resumes
  # the world.
  #
  # Set `details` to true to print individual fiber details.
  def self.print_runtime_status(details = false) : Nil
    Thread.stop_world

    Crystal::System.print_error("sched.details time=%u\n", Crystal::System::Time.ticks)

    ExecutionContext.unsafe_each do |execution_context|
      print_runtime_status(execution_context, details)
    end

    Thread.start_world
  end

  private def self.print_runtime_status(execution_context : ExecutionContext::MultiThreaded, details = false) : Nil
    Crystal::System.print_error("%s name=%s global_queue.size=%d\n",
                                execution_context.class.name,
                                execution_context.name,
                                execution_context.@global_queue.size)

    execution_context.@threads.each do |thread|
      print_runtime_status(thread, details)
    end

    return unless details

    Fiber.unsafe_each do |fiber|
      if fiber.execution_context? == execution_context
        print_runtime_status(fiber)
      end
    end
  end

  private def self.print_runtime_status(execution_context : ExecutionContext::SingleThreaded, details = false) : Nil
    Crystal::System.print_error("%s name=%s global_queue.size=%d\n",
                                execution_context.class.name,
                                execution_context.name,
                                execution_context.@global_queue.size)

    print_runtime_status(execution_context.@thread, details)

    return unless details

    Fiber.unsafe_each do |fiber|
      if fiber.execution_context? == execution_context
        print_runtime_status(fiber)
      end
    end
  end

  private def self.print_runtime_status(execution_context : ExecutionContext::Isolated, details = false) : Nil
    Crystal::System.print_error("%s name=%s\n", execution_context.class.name, execution_context.name)
    print_runtime_status(execution_context.@thread, details = false)
  end

  private def self.print_runtime_status(thread : Thread, details = false) : Nil
    thread_handle =
      {% if flag?(:linux) %}
        Pointer(Void).new(thread.@system_handle)
      {% else %}
        thread.@system_handle
      {% end %}

      case scheduler = thread.current_scheduler?
      when ExecutionContext::MultiThreaded::Scheduler
        Crystal::System.print_error("  Scheduler name=%s thread=%p local_queue.size=%u status=%s\n",
                                    scheduler.name,
                                    thread_handle,
                                    scheduler.@runnables.size,
                                    scheduler.status)
      when ExecutionContext::SingleThreaded
        Crystal::System.print_error("  Scheduler name=%s thread=%p local_queue.size=%u status=%s\n",
                                    scheduler.name,
                                    thread_handle,
                                    scheduler.@runnables.size,
                                    scheduler.status)
      when ExecutionContext::Isolated
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

  # TODO: print the fiber status: running, queued (local, global), sleeping, suspended, ...
  private def self.print_runtime_status(fiber : Fiber) : Nil
    Crystal::System.print_error("  Fiber %p name=%s\n", fiber.as(Void*), fiber.name)
  end

  # private def self.print_runtime_status(arg : Nil, details = false) : Nil
  # end
end
