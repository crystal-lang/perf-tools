# A simple in-memory memory profiler that tracks all allocations and
# deallocations by the garbage-collecting allocator.
#
# Only Linux is supported at the moment.
#
# To use the profiler, simply require this file in your project. By default, the
# profiler is enabled at program startup and does nothing else,
# `MemProf.log(io : IO)` should be called regularly to print a table of all
# allocated objects to the given `IO`:
#
# ```
# require "memprof"
#
# class Foo
# end
#
# arr = Array.new(100000) { Foo.new }
# MemProf.log(STDOUT)
# ```
#
# The above prints something like:
#
# ```text
# | Allocations | Total size | Context |
# |------------:|-----------:|---------|
# |       1 | 800,000 | `src/primitives.cr:164:3 in 'malloc'`<br>`src/array.cr:122:17 in 'initialize'`<br>`src/array.cr:112:3 in 'new'`<br>`src/array.cr:183:5 in '__crystal_main'`<br>`src/crystal/main.cr:129:5 in 'main_user_code'` |
# | 100,000 | 400,000 | `src/primitives.cr:36:1 in 'new'`<br>`usr/test.cr:6:27 in '__crystal_main'`<br>`src/crystal/main.cr:129:5 in 'main_user_code'`<br>`src/crystal/main.cr:115:7 in 'main'`<br>`src/crystal/main.cr:141:3 in 'main'` |
# ```
#
# The `Allocations` column shows the total number of live objects, which is the
# number of allocations minus the number of deallocations, including those from
# garbage collection events.
#
# The `Total size` column shows the total byte size of all live allocations.
#
# The `Context` column shows the top of the call stack that produced the
# allocations on a given row. All allocations are grouped by this call stack,
# then sorted in descending order by total sizes.
#
# We could continue this example by truncating the array and printing the stats
# again:
#
# ```
# arr.truncate(0, 1000)
# MemProf.log(STDOUT)
# ```
#
# ```text
# | Allocations | Total size | Context |
# |------------:|-----------:|---------|
# |     1 | 800,000 | `src/primitives.cr:164:3 in 'malloc'`<br>`src/array.cr:122:17 in 'initialize'`<br>`src/array.cr:112:3 in 'new'`<br>`src/array.cr:183:5 in '__crystal_main'`<br>`src/crystal/main.cr:129:5 in 'main_user_code'` |
# | 1,184 |   4,736 | `src/primitives.cr:36:1 in 'new'`<br>`usr/test.cr:6:27 in '__crystal_main'`<br>`src/crystal/main.cr:129:5 in 'main_user_code'`<br>`src/crystal/main.cr:115:7 in 'main'`<br>`src/crystal/main.cr:141:3 in 'main'` |
# ```
#
# Observe that most of the leaked `Foo`s have been freed. The exact number of
# remaining allocations may change because the Boehm GC is non-deterministic.
# Note that `MemProf.log` will automatically call `GC.collect` before printing.
#
# Several build-time environment variables can configure the behavior of the
# memory profiler:
#
# * `MEMPROF_STACK_DEPTH`: Controls the number of stack frames to use in the
#   `Context` column. (Default `5`)
# * `MEMPROF_STACK_SKIP`: When obtaining a call stack, the top of the call stack
#   will always be profiling functions themselves, followed by the allocation
#   functions themselves. These provide little useful information, so they are
#   skipped by default. This environment variable controls the number of stack
#   frames to skip; there is usually no reason to alter this. (Default `4`)
# * `MEMPROF_MIN_BYTES`: Controls the minimum total size in bytes for which an
#   allocation group is shown. This can be used to hide small objects that are
#   only allocated very few times, e.g. constants. (Default `1024`)
# * `MEMPROF_PRINT_AT_EXIT`: If set to `1`, prints all memory stats to the
#   error stream upon normal program exit, by `at_exit { MemProf.log(STDERR) }`.
#
# NOTE: As an in-memory profiler, `MemProf` will consume additional memory in
# the same process as the program being profiled. The amount of additional
# memory is proportional to the number of live allocations and
# `MEMPROF_STACK_DEPTH`.
module MemProf
  class_property? running = true

  {% begin %}
    STACK_DEPTH = {{ (env("MEMPROF_STACK_DEPTH") || "5").to_i }}

    STACK_SKIP = {{ (env("MEMPROF_STACK_SKIP") || "4").to_i }}

    MIN_BYTES = {{ (env("MEMPROF_MIN_BYTES") || "1024").to_i }}

    PRINT_AT_EXIT = {{ env("MEMPROF_PRINT_AT_EXIT") == "1" }}
  {% end %}

  {% begin %}
    STACK_TOTAL = {{ STACK_DEPTH + STACK_SKIP }}
  {% end %}

  # must be UInt64 so that `Key` itself is allocated atomically
  private record AllocInfo, size : UInt64, key : StaticArray(UInt64, STACK_DEPTH)

  class_getter alloc_infos : Hash(UInt64, AllocInfo) do
    stopping { Hash(UInt64, AllocInfo).new }
  end

  def self.track(ptr : Void*, size : UInt64) : Void* forall T
    if running?
      stopping do
        stack = StaticArray(Void*, STACK_TOTAL).new(Pointer(Void).null)
        Exception::CallStack.unwind_to(stack.to_slice)
        key = StaticArray(UInt64, STACK_DEPTH).new { |i| stack.unsafe_fetch(STACK_SKIP).address }
        alloc_infos[ptr.address] = AllocInfo.new(size, key)
      end
    end
    ptr
  end

  def self.untrack(ptr : Void*) forall T
    if running?
      stopping do
        alloc_infos.delete(ptr.address)
      end
    end
  end

  def self.stopping(&)
    if @@running
      @@running = false
      gc_enabled = LibGC.is_disabled == 0
      GC.disable if gc_enabled
      begin
        yield
      ensure
        GC.enable if gc_enabled
        @@running = true
      end
    else
      yield
    end
  end

  def self.log(io : IO) : Nil
    GC.collect
    stopping do
      all_stats = self.alloc_infos.group_by do |_, info|
        info.key
      end.map do |key, infos|
        total_size = infos.sum { |_, info| info.size }
        count = infos.size
        {count, total_size, key, count.format, total_size.format}
      end.sort_by! do |count, total_size, key, _, _|
        {~total_size, ~count, key}
      end

      all_stats.truncate(0...all_stats.index { |_, total_size, _, _, _| total_size < MIN_BYTES })

      io.puts "| Allocations | Total size | Context |"
      io.puts "|------------:|-----------:|---------|"
      next if all_stats.empty?

      count_maxlen = all_stats.max_of &.[3].size
      total_size_maxlen = all_stats.max_of &.[4].size

      all_stats.each do |_, _, key, count_str, total_size_str|
        io << "| "
        count_str.rjust(io, count_maxlen)
        io << " | "
        total_size_str.rjust(io, total_size_maxlen)
        io << " | "
        stack = [] of Void*
        key.each { |address| break if address.zero?; stack << Pointer(Void).new(address) }
        trace = Exception::CallStack.new(__callstack: stack).printable_backtrace
        trace.join(io, "<br>") { |entry| io << '`' << entry << '`' }
        io << " |\n"
      end
    end
  end

  {% if PRINT_AT_EXIT %}
    at_exit { MemProf.log(STDERR) }
  {% end %}
end

module GC
  # :nodoc:
  def self.malloc(size : LibC::SizeT) : Void*
    ptr = MemProf.track(previous_def, size.to_u64)
    LibGC.register_finalizer_ignore_self(ptr, ->(obj, data) { MemProf.untrack(obj) }, nil, nil, nil)
    ptr
  end

  # :nodoc:
  def self.malloc_atomic(size : LibC::SizeT) : Void*
    ptr = MemProf.track(previous_def, size.to_u64)
    LibGC.register_finalizer_ignore_self(ptr, ->(obj, data) { MemProf.untrack(obj) }, nil, nil, nil)
    ptr
  end

  # :nodoc:
  def self.realloc(ptr : Void*, size : LibC::SizeT) : Void*
    MemProf.untrack(ptr)
    ptr = MemProf.track(previous_def, size.to_u64)
    LibGC.register_finalizer_ignore_self(ptr, ->(obj, data) { MemProf.untrack(obj) }, nil, nil, nil)
    ptr
  end

  # :nodoc:
  def self.free(pointer : Void*) : Nil
    MemProf.untrack(pointer)
    previous_def
  end

  private def self.add_finalizer_impl(object : T) forall T
    LibGC.register_finalizer_ignore_self(object.as(Void*),
      ->(obj, data) do
        obj.as(T).finalize
        MemProf.untrack(obj)
      end,
      nil, nil, nil)
    nil
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
