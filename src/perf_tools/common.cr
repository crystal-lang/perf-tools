# :nodoc:
module PerfTools
  # A collection of non-intersecting, sorted intervals representing pointer
  # addresses. (The element type must be an integer to avoid false references.)
  # Used to perform breadth-first searches over the GC heap for connected
  # objects. Satisfies:
  #
  # ```
  # @parts.all? { |(b, e)| b < e } &&
  #   @parts.each_cons_pair.all? { |(b1, e1), (b2, e2)| e1 < b2 - 1 }
  # ```
  #
  # TODO: a few more overflow checks can probably be dropped
  struct Intervals
    def initialize(@parts : Array({UInt64, UInt64}))
    end

    def self.new
      new([] of {UInt64, UInt64})
    end

    def dup
      Intervals.new(@parts.dup)
    end

    def add(start : UInt64, count : UInt64) : Nil
      return unless count > 0
      lo = start
      hi = start + (count &- 1)

      if !@parts.empty? && (lo_index = lo == 0 ? 0 : @parts.bsearch_index { |(_, e), _| e >= lo &- 1 })
        hi_index = hi == UInt64::MAX ? nil : @parts.bsearch_index { |(b, _), _| b > hi &+ 1 }
        @parts.each(within: lo_index...hi_index) do |b, e|
          lo = {lo, b}.min
          hi = {hi, e}.max
        end
        @parts[lo_index...hi_index] = {lo, hi}
      else
        @parts << {lo, hi}
      end
    end

    def delete(start : UInt64, count : UInt64) : Nil
      return unless count > 0

      return unless lo_index = @parts.bsearch_index { |(_, e), _| e >= start }

      hi_index = (lo_index...@parts.size).bsearch do |i|
        b, _ = @parts.unsafe_fetch(i)
        b >= start + count
      end || @parts.size
      return unless lo_index < hi_index

      overlap_first = @parts.unsafe_fetch(lo_index)
      overlap_last = @parts.unsafe_fetch(hi_index - 1)

      left = {overlap_first[0], {overlap_first[1], start - 1}.min}
      right = { {overlap_last[0], start + count}.max, overlap_last[1] }

      case {left[0] <= left[1], right[0] <= right[1]}
      in {false, false}
        @parts.delete_at(lo_index...hi_index)
      in {false, true}
        @parts[lo_index...hi_index] = right
      in {true, false}
        @parts[lo_index...hi_index] = left
      in {true, true}
        @parts[lo_index...hi_index] = [left, right]
      end
    end

    def size : UInt64
      @parts.sum { |b, e| e &- b &+ 1 }
    end

    def empty? : Bool
      @parts.empty?
    end

    def each(&) : Nil
      @parts.each do |b, e|
        yield b, e &- b &+ 1
      end
    end
  end
end

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
