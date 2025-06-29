require "./common"
require "../core_ext/gc/boehm"

# Functions to produce binary dumps of the running process's GC heap, useful for
# out-of-memory analysis.
#
# Methods in this module are independent from other tools like `MemProf`.
module PerfTools::DumpHeap
  # Dumps a compact representation of the GC heap to the given *io*, sufficient
  # to reconstruct all pointers between allocations.
  #
  # All writes to *io* must not allocate memory using the GC. For `IO::Buffered`
  # this can be achieved by disabling write buffering (`io.sync = true`).
  #
  # The binary dump consists of a sequential list of allocation records. Each
  # record contains the following fields, all 64-bit little-endian integers,
  # unless otherwise noted:
  #
  # * The base address of the allocation.
  # * The byte size of the allocation. This may be larger than the size
  #   originally passed to `GC.malloc` or a similar method, as the GC may
  #   reserve trailing padding bytes for alignment. Additionally, for an atomic
  #   allocation, the the most significant bit of this field is set as well.
  # * The pointer-sized word at the start of the allocation. If this allocation
  #   corresponds to an instance of a Crystal reference type, the lower bytes
  #   will contain that type's ID.
  # * If the allocation is non-atomic, then for each inner pointer, the field
  #   offset relative to the allocation base and the pointer value are written;
  #   this list is terminated by a single `UInt64::MAX` field. Atomic records do
  #   not have this list.
  #
  # All the records are then terminated by a single `UInt64::MAX` field.
  def self.graph(io : IO) : Nil
    GC.collect

    GC.each_reachable_object do |obj, bytes|
      is_atomic = GC.atomic?(obj)
      io.write_bytes(obj.address.to_u64!)
      io.write_bytes(bytes.to_u64! | (is_atomic ? Int64::MIN : 0_i64))

      ptr = obj.as(Void**)
      io.write_bytes(ptr.value.address.to_u64!)

      unless is_atomic
        b = ptr
        e = (obj + bytes).as(Void**)
        while ptr < e
          inner = ptr.value
          if GC.is_heap_ptr(inner)
            io.write_bytes((ptr.address &- b.address).to_u64!)
            io.write_bytes(inner.address.to_u64!)
          end
          ptr += 1
        end
        io.write_bytes(UInt64::MAX)
      end
    end

    io.write_bytes(UInt64::MAX)
  end

  # Dumps the contents of the GC heap to the given *io*.
  #
  # All writes to *io* must not allocate memory using the GC. For `IO::Buffered`
  # this can be achieved by disabling write buffering (`io.sync = true`).
  #
  # The binary dump consists of a sequential list of allocation records. Each
  # record contains the following fields, all 64-bit little-endian integers,
  # unless otherwise noted:
  #
  # * The base address of the allocation.
  # * The byte size of the allocation. This may be larger than the size
  #   originally passed to `GC.malloc` or a similar method, as the GC may
  #   reserve trailing padding bytes for alignment. Additionally, for an atomic
  #   allocation, the most significant bit of this field is set as well.
  # * The full contents of the allocation.
  #
  # All the records are then terminated by a single `UInt64::MAX` field.
  def self.full(io : IO) : Nil
    GC.collect

    GC.each_reachable_object do |obj, bytes|
      io.write_bytes(obj.address.to_u64!)
      io.write_bytes(bytes.to_u64! | (GC.atomic?(obj) ? Int64::MIN : 0_i64))
      io.write(obj.as(UInt8*).to_slice(bytes)) # TODO: 32-bit overflow?
    end

    io.write_bytes(UInt64::MAX)
  end
end
