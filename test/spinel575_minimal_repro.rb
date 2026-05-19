# Minimal repro for matz/spinel#575 -- 26 lines, no requires, no
# module nesting, no external library dependencies. Maintained here
# so future tep work can re-verify whether the upstream poly-receiver
# narrowing has been tightened. Confirmed failing on spinel master
# c6dbbcc (2026-05-19) with the original tep error shape:
#
#   sp_file_write(lv_path, _t2);
#   ^- argument 2 expected `const char *`, got `sp_RbVal`
#
# Linked from issue #575 (https://github.com/matz/spinel/issues/575).

class Worker
  def run(item)
    item + ""
  end
end

class Other < Worker
  def run(item)
    item + "!"
  end
end

# Unrelated to Worker. Never instantiated. Its `run` has zero args
# and returns Integer. Pulled into the @worker.run dispatch table
# anyway -- that's the bug.
class Unrelated
  def run
    1
  end
end

class Pool
  attr_accessor :worker
  def initialize(w); @worker = w; end
  def go(item, path)
    File.write(path, @worker.run(item))
    0
  end
end

# Two distinct constructor callsites with different worker types.
# The single-arm narrowing path handles a single Pool.new(X) case
# correctly (direct call, no dispatch); two arms force the widening
# and expose the leak.
Pool.new(Worker.new).go("a", "/tmp/r1")
Pool.new(Other.new).go("b", "/tmp/r2")
