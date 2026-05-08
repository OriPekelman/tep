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

task default: :test
