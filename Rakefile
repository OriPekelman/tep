require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/test_*.rb"]
  t.warning    = false
end

desc "Build all examples and the bench binary (requires SPINEL on PATH)"
task :build do
  sh "make all"
end

desc "Remove built artefacts"
task :clean do
  sh "make clean"
end

namespace :rbs do
  desc "Syntax-validate every signature under sig/."
  task :validate do
    # `rbs validate` walks each loaded file and checks well-formedness
    # (parser, generics arity, reference resolution within the loaded
    # set). It does NOT cross-check .rb against .rbs -- that's Steep's
    # job, deferred until the surface stabilises.
    sh "rbs --repo sig -I sig validate"
  end
end

task default: :test
