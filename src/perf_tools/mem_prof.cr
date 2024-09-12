require "./common"

# A simple in-memory memory profiler that tracks all allocations and
# deallocations by the garbage-collecting allocator.
#
# Only Linux is supported at the moment.
#
# To use the profiler, simply require this file in your project. By default, the
# profiler is enabled at program startup and does nothing else.
# `MemProf.pretty_log_allocations(io : IO)` should be called regularly to print
# a table of all allocated objects to the given `IO`:
#
# ```
# require "perf_tools/mem_prof"
#
# class Foo
# end
#
# arr = Array.new(100000) { Foo.new }
# MemProf.pretty_log_allocations(STDOUT)
# ```
#
# The above prints something like:
#
# ```text
# | Allocations | Total size | Context |
# |------------:|-----------:|---------|
# |       1 | 800,000 | `/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/array.cr:122:17 in 'initialize'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/array.cr:112:3 in 'new'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/array.cr:183:5 in '__crystal_main'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:129:5 in 'main_user_code'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:115:7 in 'main'` |
# | 100,000 | 400,000 | `/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/primitives.cr:36:1 in 'new'`<br>`usr/test.cr:6:27 in '__crystal_main'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:129:5 in 'main_user_code'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:115:7 in 'main'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:141:3 in 'main'` |
# ```
#
# We could continue this example by truncating the array and printing the stats
# again:
#
# ```
# arr.truncate(0, 1000)
# MemProf.pretty_log_allocations(STDOUT)
# ```
#
# ```text
# | Allocations | Total size | Context |
# |------------:|-----------:|---------|
# |     1 | 800,000 | `/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/array.cr:122:17 in 'initialize'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/array.cr:112:3 in 'new'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/array.cr:183:5 in '__crystal_main'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:129:5 in 'main_user_code'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:115:7 in 'main'` |
# | 1,184 |   4,736 | `/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/primitives.cr:36:1 in 'new'`<br>`usr/test.cr:6:27 in '__crystal_main'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:129:5 in 'main_user_code'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:115:7 in 'main'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:141:3 in 'main'` |
# ```
#
# Observe that most of the leaked `Foo`s have been freed. The exact number of
# remaining allocations may change because the Boehm GC is non-deterministic.
#
# `MemProf.log_allocations(io : IO)` could be used instead for a more
# machine-readable output format. Additionally,
# `MemProf.log_object_counts(io : IO)` and `MemProf.log_object_sizes(io : IO)`
# are available to tally the counts and heap sizes of all live objects of most
# reference types.
#
# All logging methods in this module will automatically call `GC.collect` before
# printing.
#
# NOTE: As an in-memory profiler, `MemProf` will consume additional memory in
# the same process as the program being profiled. The amount of additional
# memory is proportional to the number of live allocations and
# `MemProf::STACK_DEPTH`.
module PerfTools::MemProf
  # :nodoc:
  class_property? running = true

  {% begin %}
    # The maximum number of stack frames shown for `MemProf.log_allocations` and
    # `MemProf.pretty_log_allocations`.
    #
    # Configurable at build time using the `MEMPROF_STACK_DEPTH` environment
    # variable.
    STACK_DEPTH = {{ (env("MEMPROF_STACK_DEPTH") || "5").to_i }}

    # When obtaining a call stack, the top of the call stack will always be the
    # profiling functions themselves, followed by the allocation functions
    # themselves. These provide little useful information, so they are skipped
    # by default. This constant controls the number of stack frames to skip;
    # there is usually no reason to alter this.
    #
    # Configurable at build time using the `MEMPROF_STACK_SKIP` environment
    # variable.
    STACK_SKIP = {{ (env("MEMPROF_STACK_SKIP") || "5").to_i }}

    # The minimum total byte size below which an allocation group is hidden for
    # `MemProf.log_allocations` and `MemProf.pretty_log_allocations`. This can
    # be used to hide small objects that are only allocated very few times, e.g.
    # constants.
    #
    # Configurable at run time using the `MEMPROF_MIN_BYTES` environment
    # variable.
    MIN_BYTES = ENV["MEMPROF_MIN_BYTES"]?.try(&.to_i) || 1024

    # If set to `1`, logs all allocations to the standard error stream upon
    # normal program exit, via `at_exit { MemProf.log_allocations(STDERR) }`.
    #
    # Configurable at run time using the `MEMPROF_PRINT_AT_EXIT` environment
    # variable.
    PRINT_AT_EXIT = ENV["MEMPROF_PRINT_AT_EXIT"]? == "1"

    # The maximum number of objects to track in `MemProf.pretty_log_object_graph`.
    # 0 is "unlimited". Defaults to 10.
    #
    # Configurable at run time using the `MEMPROF_REF_LIMIT` environment
    # variable.
    REF_LIMIT = (ENV["MEMPROF_REF_LIMIT"]? || "10").to_i

    # The maximum number of indirections to track `MemProf.pretty_log_object_graph`.
    # 0 is "unlimited". Defaults to 5.
    #
    # Configurable at run time using the `MEMPROF_REF_LEVEL` environment
    # variable.
    REF_LEVEL = (ENV["MEMPROF_REF_LEVEL"]? || "5").to_i
  {% end %}

  {% begin %}
    # :nodoc:
    STACK_TOTAL = {{ STACK_DEPTH + STACK_SKIP }}
  {% end %}

  # must be UInt64 so that `Key` itself is allocated atomically
  private record AllocInfo, size : UInt64, key : StaticArray(UInt64, STACK_DEPTH), type_id : Int32, atomic : Bool

  # :nodoc:
  class_getter alloc_infos : Hash(UInt64, AllocInfo) do
    stopping { Hash(UInt64, AllocInfo).new }
  end

  # :nodoc:
  class_getter obj_counts : Hash(Int32, UInt64) do
    {} of Int32 => UInt64
  end

  record KnownClass, name : String, fields_offsets : Hash(Int32, String)?
  # :nodoc:
  class_getter known_classes : Hash(Int32, KnownClass) do
    {} of Int32 => KnownClass
  end

  @@last_type_id = 0
  @@last_type_name : String?
  @@last_type_fields : Hash(Int32, String)? = nil

  # :nodoc:
  def self.set_type(type : T.class, ivars : Hash(Int32, String)?, &) forall T
    @@last_type_id = T.crystal_instance_type_id
    @@last_type_name = T.name
    @@last_type_fields = ivars
    yield
  end

  # :nodoc:
  def self.track(ptr : Void*, size : UInt64, atomic : Bool) : Void* forall T
    if running?
      stopping do
        type_id, @@last_type_id = @@last_type_id, 0

        stack = StaticArray(Void*, STACK_TOTAL).new(Pointer(Void).null)
        Exception::CallStack.unwind_to(stack.to_slice)
        key = StaticArray(UInt64, STACK_DEPTH).new { |i| stack.unsafe_fetch(STACK_SKIP &+ i).address }
        alloc_infos[ptr.address] = AllocInfo.new(size, key, type_id, atomic)
        unless type_id == 0
          obj_counts = self.obj_counts
          obj_counts[type_id] = obj_counts.fetch(type_id, 0_u64) &+ 1
          known_classes[type_id] = KnownClass.new @@last_type_name.not_nil!, @@last_type_fields
        end
      end
    end
    ptr
  end

  # :nodoc:
  def self.untrack(ptr : Void*) : Bool forall T
    if running?
      stopping do
        if info = alloc_infos.delete(ptr.address)
          obj_counts[info.type_id] &-= 1 unless info.type_id == 0
          return info.atomic
        end
      end
    end
    false
  end

  private def self.stopping(&)
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

  # Logs the numbers of known live reference objects, aggregated by their types,
  # to the given *io*.
  #
  # The first line contains the number of lines that follow. After that, each
  # line includes the object count, then a `\t`, then the type name for those
  # objects. The lines do not assume any particular order. Example output:
  #
  # ```text
  # 19
  # 4       IO::FileDescriptor
  # 8       Hash(Thread, Deque(Fiber))
  # 20      Crystal::SpinLock
  # 8       Hash(Thread, Crystal::EventLoop::Event)
  # 3       Fiber
  # 1       Thread::LinkedList(Fiber)
  # 1       Thread
  # 1       Thread::LinkedList(Thread)
  # 1       Crystal::Scheduler
  # 1       Crystal::LibEvent::EventLoop
  # 3       Deque(Fiber)
  # 2       Mutex
  # 1       Hash(Signal, Proc(Signal, Nil))
  # 1       Hash(Tuple(UInt64, Symbol), Bool)
  # 1       Hash(UInt64, UInt64)
  # 1       Hash(Thread, Pointer(LibPCRE2::JITStack))
  # 1       Hash(Int32, Int32)
  # 1       Hash(Int32, Channel(Int32))
  # 1       Hash(String, NamedTuple(time: Time, location: Time::Location))
  # ```
  def self.log_object_counts(io : IO) : Nil
    GC.collect
    stopping do
      lines = known_classes.count do |type_id, _|
        obj_counts.fetch(type_id, 0_u64) > 0
      end

      io << lines << '\n'
      known_classes.each do |type_id, klass|
        count = obj_counts.fetch(type_id, 0_u64)
        next unless count > 0
        io << count << '\t' << klass.name << '\n'
      end
    end
  end

  # Logs the total sizes of known live reference objects, aggregated by their
  # types, to the given *io*.
  #
  # The "size" of an object includes the space it occupies on the heap. If the
  # object was not allocated using `GC.malloc_atomic`, then its "size" also
  # includes, recursively, the "sizes" of its reference-type instance variables,
  # except that the same space is never counted more than once.
  #
  # The "total size" of a reference type is then the total "sizes" of all of its
  # live objects, except again that the same heap space is never counted more
  # than once. Alternatively it is the total number of heap bytes transitively
  # reachable from all live objects via pointers.
  #
  # The first line contains the number of lines that follow. After that, each
  # line includes the total size, then a `\t`, then the type name for those
  # objects. The lines do not assume any particular order. Example output:
  #
  # ```text
  # 26
  # 4       (class 88)
  # 216     (class 131)
  # 80      Crystal::SpinLock
  # 16      (class 87)
  # 24      (class 20)
  # 72      (class 4)
  # 24      (class 137)
  # 24      (class 157)
  # 1984    IO::FileDescriptor
  # 448     Hash(Thread, Deque(Fiber))
  # 448     Hash(Thread, Crystal::EventLoop::Event)
  # 600     Fiber
  # 704     Thread::LinkedList(Fiber)
  # 600     Thread
  # 400     Thread::LinkedList(Thread)
  # 652     Crystal::Scheduler
  # 24      Crystal::LibEvent::EventLoop
  # 560     Deque(Fiber)
  # 168     Mutex
  # 152     Hash(Signal, Proc(Signal, Nil))
  # 56      Hash(Tuple(UInt64, Symbol), Bool)
  # 56      Hash(UInt64, UInt64)
  # 56      Hash(Thread, Pointer(LibPCRE2::JITStack))
  # 56      Hash(Int32, Int32)
  # 56      Hash(Int32, Channel(Int32))
  # 56      Hash(String, NamedTuple(time: Time, location: Time::Location))
  # ```
  #
  # NOTE: Some classes do not have their names known. This affects only a small
  # number of types in the standard library runtime.
  def self.log_object_sizes(io : IO) : Nil
    GC.collect
    stopping do
      alloc_infos = self.alloc_infos

      counts = {} of Int32 => UInt64
      references = {} of Int32 => PerfTools::Intervals

      alloc_infos.each do |ptr, info|
        next if info.type_id == 0 # skip allocations with no type info
        if info.atomic
          counts[info.type_id] = counts.fetch(info.type_id, 0_u64) &+ info.size
        else
          referenced = references[info.type_id] ||= PerfTools::Intervals.new
          referenced.add(ptr, info.size)
        end
      end

      references.each do |type_id, referenced|
        frontier = referenced.dup

        until frontier.empty?
          new_frontier = PerfTools::Intervals.new
          referenced.each do |start, size|
            each_inner_pointer(Pointer(Void*).new(start), size) do |subptr|
              next unless subinfo = alloc_infos[subptr.address]?
              referenced.add(subptr.address, subinfo.size)
              new_frontier.add(subptr.address, subinfo.size) unless subinfo.atomic
            end
          end
          referenced.each do |start, size|
            new_frontier.delete(start, size)
          end
          frontier = new_frontier
        end

        counts[type_id] = counts.fetch(type_id, 0_u64) &+ referenced.size
      end

      io << counts.size << '\n'
      counts.each do |type_id, bytes|
        io << bytes << '\t'
        if klass = known_classes[type_id]?
          io << klass.name
        else
          io << "(class " << type_id << ")"
        end
        io << '\n'
      end
    end
  end

  # Logs the objects that are transitively reachable to a given *type* of objects,
  # outputing a mermaid graph to the given *io*. The graph contains an indication of
  # the field that links an object, or its index if the field is not known.
  #
  # Example:
  #
  # ```
  # class A
  #   @bs = Array(B).new
  #
  #   def add(b : B)
  #     @bs << b
  #   end
  # end
  #
  # class B
  #   @c : C
  #
  #   def initialize(@c : C)
  #   end
  # end
  #
  # class C; end
  #
  # a = A.new
  # a.add(B.new C.new)
  # a.add(B.new C.new)
  #
  # PerfTools::MemProf.pretty_log_object_graph STDOUT, C
  # ```
  #
  # produces the following graph:
  #
  # ```mermaid
  # graph LR
  #   0x109736e80["0x109736e80 C"]
  #   0x109736e70["0x109736e70 C"]
  #   0x10972fe40["0x10972fe40 B"] --@c,0--> 0x109736e80
  #   0x10972fe20["0x10972fe20 (class 0)"] --@(field 0),1--> 0x10972fe40
  #   0x10972fe60["0x10972fe60 Array(B)"] --@(field 16),2--> 0x10972fe20
  #   0x10972fe80["0x10972fe80 A"] --@bs,3--> 0x10972fe60
  #   0x10972fe00["0x10972fe00 B"] --@c,0--> 0x109736e70
  #   0x10972fe20["0x10972fe20 (class 0)"] --@(field 8),1--> 0x10972fe00
  # ```
  #
  # `(class 0)` is the buffer of the array. The number next to the field is the level of indirection,
  # counting as 0 for the objects that direct links to an object of the given *type*, 1 for the objects
  # that have a direct link to an object of the given *type*, and so on.
  #
  # The graph is limited to `REF_LIMIT` objects and `REF_LEVEL` levels of indirection.
  def self.pretty_log_object_graph(io : IO, type : T.class) : Nil forall T
    GC.collect
    stopping do
      type_id = T.crystal_instance_type_id
      alloc_infos = self.alloc_infos

      pointers = Hash(UInt64, Int32).new(REF_LIMIT == 0 ? 10 : REF_LIMIT)

      alloc_infos.each do |ptr, info|
        next unless info.type_id == type_id
        pointers[ptr] = 0
        break if REF_LIMIT > 0 && pointers.size >= REF_LIMIT
      end

      original_pointers = pointers.keys

      referees = Array({UInt64, UInt64, String, Int32}).new

      visited = [] of UInt64

      alloc_infos.each do |ptr, info|
        next if info.atomic

        next if visited.includes? ptr

        init = info.type_id == 0 ? -sizeof(Void*) : 0

        stack = [{ptr, init, info.size}]
        until stack.empty?
          ptr, offset, size = stack.pop
          offset += sizeof(Void*) # we know that at 0 there is the type_id, no need to check it

          next if offset >= size

          stack << {ptr, offset, size}
          value_ptr = Pointer(Void*).new(ptr + offset)
          subptr = value_ptr.value.address

          if (level = pointers[subptr]?) && (REF_LEVEL == 0 || level < REF_LEVEL)
            stack << {subptr, 0, 0_u64}

            stack.reverse.each_cons_pair do |to, from|
              from_ptr, from_offset, _ = from
              to_ptr, _, _ = to
              if info = alloc_infos[from_ptr]?
                field = known_classes[info.type_id]?.try(&.fields_offsets.try { |fo| fo[from_offset]? }) || "(field #{from_offset})"
              else
                field = "(field #{from_offset})"
              end

              tuple = {from_ptr, to_ptr, field, level}
              unless referees.includes? tuple
                pointers[from_ptr] = level + 1
                pointers[to_ptr] = level
                referees << tuple
              end
              level += 1
              break if REF_LEVEL > 0 && level >= REF_LEVEL
            end
            stack.pop
          elsif level
            # do nothing
          elsif (subinfo = alloc_infos[subptr]?) && !subinfo.atomic && !visited.includes? subptr
            init = subinfo.type_id == 0 ? -sizeof(Void*) : 0
            stack << {subptr, init, subinfo.size}
          end

          visited << subptr
        end
      end

      io << "graph LR\n"

      original_pointers.each do |ptr|
        if info = alloc_infos[ptr]?
          name = known_classes[info.type_id]?.try(&.name) || "(class #{info.type_id})"
          io << "  0x" << ptr.to_s(16) << "[\"0x" << ptr.to_s(16) << " " << name << "\"]\n"
        end
      end

      referees.each do |ref|
        from, to, field, level = ref
        if info = alloc_infos[from]?
          name = known_classes[info.type_id]?.try(&.name) || "(class #{info.type_id})"
        else
          name = "(class 0)"
        end
        io << "  0x" << from.to_s(16) << "[\"0x" << from.to_s(16) << " " << name << "\"] --@" << field << "," << level << "--> 0x" << to.to_s(16) << "\n"
      end
    end
  end

  # Returns the total number of heap bytes occupied by *object*.
  #
  # This is the same per-object "size" defined in `.log_object_sizes`.
  #
  # Returns zero for string literals, as they are never allocated on the heap.
  # Might also return zero for certain constants which are initialized before
  # `MemProf` is activated.
  def self.object_size(object : Reference) : UInt64
    alloc_infos = self.alloc_infos
    return 0_u64 unless info = alloc_infos[object.object_id]?

    referenced = PerfTools::Intervals.new
    referenced.add(object.object_id, info.size)
    frontier = referenced.dup

    until frontier.empty?
      new_frontier = PerfTools::Intervals.new
      referenced.each do |start, size|
        each_inner_pointer(Pointer(Void*).new(start), size) do |subptr|
          next unless subinfo = alloc_infos[subptr.address]?
          referenced.add(subptr.address, subinfo.size)
          new_frontier.add(subptr.address, subinfo.size) unless subinfo.atomic
        end
      end
      referenced.each do |start, size|
        new_frontier.delete(start, size)
      end
      frontier = new_frontier
    end

    referenced.size
  end

  private def self.each_inner_pointer(ptr : Void**, size : Int, &)
    # this counts only pointers that are pointer-aligned
    (size // sizeof(Void*)).times do |i|
      yield ptr.value
      ptr += 1
    end
  end

  # Logs the total sizes of known live allocations, aggregated by their call
  # stacks, to the given *io*.
  #
  # The behavior of this method can be controlled by the `STACK_DEPTH`,
  # `STACK_SKIP`, and `MIN_BYTES` constants.
  #
  # The first line contains the number of lines that follow. After that, each
  # line includes the allocation count, the total byte size of the allocations,
  # then the call stack, separated by `\t`s. The lines do not assume any
  # particular order. Example output: (`MIN_BYTES == 150`)
  #
  # ```text
  # 7
  # 1       256     /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/file_descriptor.cr:21:3 in 'new'        /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/file_descriptor.cr:191:5 in 'from_stdio'      /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/file_descriptor.cr:40:5 in 'from_stdio' /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/kernel.cr:25:10 in '~STDOUT:init' /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/kernel.cr:25:1 in '__crystal_main'
  # 1       256     /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/file_descriptor.cr:21:3 in 'new'        /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/file_descriptor.cr:191:5 in 'from_stdio'      /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/file_descriptor.cr:40:5 in 'from_stdio' /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/kernel.cr:42:10 in '~STDERR:init' /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/once.cr:25:54 in 'once'
  # 1       152     /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/fiber.cr:88:3 in 'new'     /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/concurrent.cr:61:3 in 'spawn:name'        /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/kernel.cr:558:1 in '__crystal_main'        /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:129:5 in 'main_user_code' /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:115:7 in 'main'
  # 1       152     /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/fiber.cr:125:3 in 'new'    /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/pthread.cr:42:19 in 'initialize'      /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/pthread.cr:39:3 in 'new'       /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/pthread.cr:62:3 in 'current'  /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/scheduler.cr:26:5 in 'enqueue'
  # 1       152     /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/fiber.cr:88:3 in 'new'     /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/concurrent.cr:61:3 in 'spawn:name'        /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/signal.cr:60:5 in 'start_loop' /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/signal.cr:163:5 in 'setup_default_handlers'   /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/kernel.cr:558:1 in '__crystal_main'
  # 1       256     /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/file_descriptor.cr:21:3 in 'new'        /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/file_descriptor.cr:158:9 in 'pipe'    /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io.cr:141:5 in 'pipe'      /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/signal.cr:15:12 in '~Crystal::System::Signal::pipe:init'      /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/once.cr:25:54 in 'once'
  # 1       256     /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/file_descriptor.cr:21:3 in 'new'        /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/file_descriptor.cr:159:9 in 'pipe'    /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io.cr:141:5 in 'pipe'      /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/signal.cr:15:12 in '~Crystal::System::Signal::pipe:init'      /opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/once.cr:25:54 in 'once'
  # ```
  def self.log_allocations(io : IO) : Nil
    GC.collect
    stopping do
      all_stats = self.alloc_infos.group_by do |_, info|
        info.key
      end.map do |key, infos|
        total_size = infos.sum { |_, info| info.size }
        count = infos.size
        {count, total_size, key}
      end

      io << all_stats.count { |_, total_size, _| total_size >= MIN_BYTES } << '\n'
      all_stats.each do |count, total_size, key|
        next if total_size < MIN_BYTES
        io << count << '\t' << total_size
        stack = [] of Void*
        key.each { |address| break if address.zero?; stack << Pointer(Void).new(address) }
        trace = Exception::CallStack.new(__callstack: stack).printable_backtrace
        trace.each { |entry| io << '\t' << entry }
        io << '\n'
      end
    end
  end

  # Logs the total sizes of known live allocations, aggregated by their call
  # stacks, to the given *io* as a Markdown table.
  #
  # The behavior of this method can be controlled by the `STACK_DEPTH`,
  # `STACK_SKIP`, and `MIN_BYTES` constants.
  #
  # The rows are sorted by each group's total size, then by allocation count,
  # and finally by the call stacks. Example output: (`MIN_BYTES == 150`)
  #
  # ```text
  # | Allocations | Total size | Context |
  # |------------:|-----------:|---------|
  # | 1 | 256 | `/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/file_descriptor.cr:21:3 in 'new'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/file_descriptor.cr:191:5 in 'from_stdio'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/file_descriptor.cr:40:5 in 'from_stdio'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/kernel.cr:25:10 in '~STDOUT:init'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/kernel.cr:25:1 in '__crystal_main'` |
  # | 1 | 256 | `/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/file_descriptor.cr:21:3 in 'new'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/file_descriptor.cr:191:5 in 'from_stdio'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/file_descriptor.cr:40:5 in 'from_stdio'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/kernel.cr:42:10 in '~STDERR:init'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/once.cr:25:54 in 'once'` |
  # | 1 | 256 | `/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/file_descriptor.cr:21:3 in 'new'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/file_descriptor.cr:158:9 in 'pipe'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io.cr:141:5 in 'pipe'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/signal.cr:15:12 in '~Crystal::System::Signal::pipe:init'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/once.cr:25:54 in 'once'` |
  # | 1 | 256 | `/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io/file_descriptor.cr:21:3 in 'new'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/file_descriptor.cr:159:9 in 'pipe'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/io.cr:141:5 in 'pipe'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/signal.cr:15:12 in '~Crystal::System::Signal::pipe:init'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/once.cr:25:54 in 'once'` |
  # | 1 | 152 | `/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/fiber.cr:125:3 in 'new'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/pthread.cr:42:19 in 'initialize'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/pthread.cr:39:3 in 'new'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/pthread.cr:62:3 in 'current'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/scheduler.cr:26:5 in 'enqueue'` |
  # | 1 | 152 | `/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/fiber.cr:88:3 in 'new'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/concurrent.cr:61:3 in 'spawn:name'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/kernel.cr:558:1 in '__crystal_main'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:129:5 in 'main_user_code'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/main.cr:115:7 in 'main'` |
  # | 1 | 152 | `/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/fiber.cr:88:3 in 'new'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/concurrent.cr:61:3 in 'spawn:name'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/signal.cr:60:5 in 'start_loop'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/crystal/system/unix/signal.cr:163:5 in 'setup_default_handlers'`<br>`/opt/homebrew/Cellar/crystal/1.9.2/share/crystal/src/kernel.cr:558:1 in '__crystal_main'` |
  # ```
  def self.pretty_log_allocations(io : IO) : Nil
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
        trace.join(io, "<br>") { |entry| PerfTools.md_code_span(io, entry) }
        io << " |\n"
      end
    end
  end

  private def self.init
    LibGC.register_disclaim_proc(
      LibGC::GC_I_PTRFREE,
      ->(ptr : Void*) { untrack(ptr); 0 },
      0,
    )

    LibGC.register_disclaim_proc(
      LibGC::GC_I_NORMAL,
      ->(ptr : Void*) { untrack(ptr); 0 },
      0,
    )

    if PRINT_AT_EXIT
      at_exit { log_allocations(STDERR) }
    end
  end

  init
end

lib LibGC
  GC_I_PTRFREE = 0
  GC_I_NORMAL  = 1

  fun register_disclaim_proc = GC_register_disclaim_proc(kind : Int, proc : Void* -> Int, mark_from_all : Int)
end

module GC
  # :nodoc:
  def self.malloc(size : LibC::SizeT) : Void*
    PerfTools::MemProf.track(previous_def, size.to_u64, false)
  end

  # :nodoc:
  def self.malloc_atomic(size : LibC::SizeT) : Void*
    PerfTools::MemProf.track(previous_def, size.to_u64, true)
  end

  # :nodoc:
  def self.realloc(ptr : Void*, size : LibC::SizeT) : Void*
    was_atomic = PerfTools::MemProf.untrack(ptr)
    PerfTools::MemProf.track(previous_def, size.to_u64, was_atomic)
  end

  # :nodoc:
  def self.free(pointer : Void*) : Nil
    PerfTools::MemProf.untrack(pointer)
    previous_def
  end
end

# This is for the system allocated classes, which doesn't trigger the `inherited` macro
{% begin %}
  {% types = Reference.all_subclasses %}
  {% for type in types %}
    {% unless type.type_vars.any?(&.is_a?(TypeNode)) %}
      class {{ type }}
        # :nodoc:
        def self.allocate
          PerfTools::MemProf.set_type(self, nil) { previous_def }
        end
      end
    {% end %}
  {% end %}
{% end %}

class Reference
  macro inherited
    # :nodoc:
    def self.allocate
      PerfTools::MemProf.set_type(self, self._fields_offsets) { previous_def }
    end
  end
end

class Object
  def self._fields_offsets
    {% begin %}
    {
      {% unless @type.private? %}
        {% for field in @type.instance_vars %}
          offsetof({{@type}}, @{{ field.name }}) => "{{ field.name.id }}",
        {% end %}
      {% end %}
    } of Int32 => String
    {% end %}
  end
end
