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
    #
    # Resolve the rbs CLI from the gem itself rather than assuming it's
    # on PATH. Under `bundle exec` (CI) the bundled rbs is on PATH; on a
    # bare host (e.g. a distro ruby on gx10 where the gem's bin dir
    # isn't exported) it is NOT, and a plain `sh "rbs ..."` fails with
    # 127. Gem.bin_path locates the executable in both setups, and we
    # run it through the current ruby so the shebang/PATH don't matter.
    args = ["--repo", "sig", "-I", "sig", "validate"]
    begin
      sh RbConfig.ruby, Gem.bin_path("rbs", "rbs"), *args
    rescue Gem::Exception
      # rbs not installed as a gem; last resort is a bare PATH lookup.
      sh "rbs", *args
    end
  end
end

task default: :test
