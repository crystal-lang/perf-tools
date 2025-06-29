lib LibGC
  GC_I_PTRFREE = 0
  GC_I_NORMAL  = 1

  fun get_kind_and_size = GC_get_kind_and_size(p : Void*, psize : SizeT*) : Int

  alias ReachableObjectFunc = Void*, SizeT, Void* -> Void

  fun enumerate_reachable_objects_inner = GC_enumerate_reachable_objects_inner(proc : ReachableObjectFunc, client_data : Void*)

  fun register_disclaim_proc = GC_register_disclaim_proc(kind : Int, proc : Void* -> Int, mark_from_all : Int)
end

module GC
  # Returns whether *ptr* is a pointer to the base of an atomic allocation.
  def self.atomic?(ptr : Pointer) : Bool
    {% if flag?(:gc_none) %}
      false
    {% else %}
      LibGC.get_kind_and_size(ptr, nil) == LibGC::GC_I_PTRFREE
    {% end %}
  end

  # Walks the entire GC heap, yielding each allocation's base address and size
  # to the given *block*.
  #
  # The *block* must not allocate memory using the GC.
  def self.each_reachable_object(&block : Void*, UInt64 ->) : Nil
    # FIXME: this is necessary to bring `block` in scope until
    # crystal-lang/crystal#15940 is resolved
    typeof(block)

    {% unless flag?(:gc_none) %}
      GC.lock_write
      begin
        LibGC.enumerate_reachable_objects_inner(LibGC::ReachableObjectFunc.new do |obj, bytes, client_data|
          fn = client_data.as(typeof(pointerof(block))).value
          fn.call(obj, bytes.to_u64!)
        end, pointerof(block))
      ensure
        GC.unlock_write
      end
    {% end %}
  end
end
