# Drive-all: run every test_*.rb under test/ in one process. Use
# `make test` or `ruby test/run_all.rb`.
require_relative "helper"

Dir[File.join(__dir__, "test_*.rb")].sort.each do |f|
  require_relative File.basename(f)
end
