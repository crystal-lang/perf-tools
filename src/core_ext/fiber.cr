# :nodoc:
class Fiber
  def status : String
    if @alive
      if @context.@resumable == 1
        "suspended"
      else
        "running"
      end
    else
      "dead"
    end
  end
end
