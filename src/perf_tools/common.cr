struct Exception::CallStack
  def initialize(*, __callstack @callstack : Array(Void*))
  end

  {% if flag?(:interpreted) %} @[Primitive(:interpreter_call_stack_unwind)] {% end %}
  def self.unwind_to(buf : Slice(Void*)) : Nil
    callstack = {buf.to_unsafe, buf.to_unsafe + buf.size}
    backtrace_fn = ->(context : LibUnwind::Context, data : Void*) do
      b, e = data.as({Void**, Void**}*).value
      return LibUnwind::ReasonCode::END_OF_STACK if b >= e
      data.as({Void**, Void**}*).value = {b + 1, e}

      ip = {% if flag?(:arm) %}
             Pointer(Void).new(__crystal_unwind_get_ip(context))
           {% else %}
             Pointer(Void).new(LibUnwind.get_ip(context))
           {% end %}
      b.value = ip

      {% if flag?(:gnu) && flag?(:i386) %}
        # This is a workaround for glibc bug: https://sourceware.org/bugzilla/show_bug.cgi?id=18635
        # The unwind info is corrupted when `makecontext` is used.
        # Stop the backtrace here. There is nothing interest beyond this point anyway.
        if CallStack.makecontext_range.includes?(ip)
          return LibUnwind::ReasonCode::END_OF_STACK
        end
      {% end %}

      LibUnwind::ReasonCode::NO_REASON
    end

    LibUnwind.backtrace(backtrace_fn, pointerof(callstack).as(Void*))
  end
end
