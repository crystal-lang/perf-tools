module PerfTools
  protected def self.md_code_span(io : IO, str : String) : Nil
    ticks = 0
    str.scan(/`+/) { |m| ticks = {ticks, m.size}.max }
    ticks.times { io << '`' }
    io << "` " << str << " `"
    ticks.times { io << '`' }
  end

  # :nodoc:
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
  {% if flag?(:win32) %}
    {% if flag?(:interpreted) %} @[Primitive(:interpreter_call_stack_unwind)] {% end %}
    def self.unwind_to(buf : Slice(Void*)) : Nil
      # TODO: use stack if possible (must be 16-byte aligned)
      context = Pointer(LibC::CONTEXT).malloc(1)
      context.value.contextFlags = LibC::CONTEXT_FULL
      LibC.RtlCaptureContext(context)

      # unlike DWARF, this is required on Windows to even be able to produce
      # correct stack traces, so we do it here but not in `libunwind.cr`
      load_debug_info

      machine_type = {% if flag?(:x86_64) %}
                      LibC::IMAGE_FILE_MACHINE_AMD64
                    {% elsif flag?(:i386) %}
                      # TODO: use WOW64_CONTEXT in place of CONTEXT
                      {% raise "x86 not supported" %}
                    {% else %}
                      {% raise "Architecture not supported" %}
                    {% end %}

      stack_frame = LibC::STACKFRAME64.new
      stack_frame.addrPC.mode = LibC::ADDRESS_MODE::AddrModeFlat
      stack_frame.addrFrame.mode = LibC::ADDRESS_MODE::AddrModeFlat
      stack_frame.addrStack.mode = LibC::ADDRESS_MODE::AddrModeFlat

      stack_frame.addrPC.offset = context.value.rip
      stack_frame.addrFrame.offset = context.value.rbp
      stack_frame.addrStack.offset = context.value.rsp

      last_frame = nil
      cur_proc = LibC.GetCurrentProcess
      cur_thread = LibC.GetCurrentThread

      buf.each_index do |i|
        ret = LibC.StackWalk64(
          machine_type,
          cur_proc,
          cur_thread,
          pointerof(stack_frame),
          context,
          nil,
          nil, # ->LibC.SymFunctionTableAccess64,
          nil, # ->LibC.SymGetModuleBase64,
          nil
        )
        break if ret == 0

        ip = Pointer(Void).new(stack_frame.addrPC.offset)
        buf.unsafe_put(i, ip)
      end
    end
  {% else %}
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
  {% end %}

  # :nodoc:
  def self.__decode_backtrace(stack : Slice(Void*)) : Array(String)
    show_full_info = ENV["CRYSTAL_CALLSTACK_FULL_INFO"]? == "1"
    frames = [] of String
    stack.each do |ip|
      frame = decode_backtrace_frame(ip, show_full_info)
      frames << frame if frame
    end
    frames
  end

  {% unless @type.class.has_method?(:decode_backtrace_frame) %} # Crystal < 1.16.0
    # :nodoc:
    def self.decode_backtrace_frame(ip, show_full_info) : String?
      pc = decode_address(ip)
      file, line_number, column_number = decode_line_number(pc)

      if file && file != "??"
        return if @@skip.includes?(file)

        # Turn to relative to the current dir, if possible
        if current_dir = CURRENT_DIR
          if rel = Path[file].relative_to?(current_dir)
            rel = rel.to_s
            file = rel unless rel.starts_with?("..")
          end
        end

        file_line_column = file
        unless line_number == 0
          file_line_column = "#{file_line_column}:#{line_number}"
          file_line_column = "#{file_line_column}:#{column_number}" unless column_number == 0
        end
      end

      if name = decode_function_name(pc)
        function = name
      elsif frame = decode_frame(ip)
        _, function, file = frame
        # Crystal methods (their mangled name) start with `*`, so
        # we remove that to have less clutter in the output.
        function = function.lchop('*')
      else
        function = "??"
      end

      if file_line_column
        if show_full_info && (frame = decode_frame(ip))
          _, sname, _ = frame
          line = "#{file_line_column} in '#{sname}'"
        else
          line = "#{file_line_column} in '#{function}'"
        end
      else
        if file == "??" && function == "??"
          line = "???"
        else
          line = "#{file} in '#{function}'"
        end
      end

      if show_full_info
        line = "#{line} at 0x#{ip.address.to_s(16)}"
      end

      line
    end
  {% end %}

  # :nodoc:
  def self.__print_frame(ip : Void*) : Nil
    repeated_frame = RepeatedFrame.new(ip)

    {% if flag?(:win32) && !flag?(:gnu) %}
      # TODO: can't merely call #print_frame because the UTF-16 to UTF-8
      # conversion is allocating strings, and it's probably a bad idea to
      # allocate while the world is stopped.
      Crystal::System.print_error "[%p] ???", repeated_frame.ip
    {% else %}
      print_frame(repeated_frame)
    {% end %}
  end
end
