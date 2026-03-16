module GC
  # Returns whether *ptr* is a pointer to the base of an atomic allocation.
  def self.atomic?(ptr : Pointer) : Bool
    false
  end

  # Walks the entire GC heap, yielding each allocation's base address and size
  # to the given *block*.
  #
  # The *block* must not allocate memory using the GC.
  def self.each_reachable_object(&block : Void*, UInt64 ->) : Nil
  end
end
