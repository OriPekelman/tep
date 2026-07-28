require "minitest/autorun"
require "tmpdir"
require "fileutils"

# tep#217 (spinel-flags leg): `tep build` applies the compile flags
# `spinel-compat vendor` wrote to vendor/spinel/spinel-flags, resolving
# project-root-relative paths, with TEP_NO_SPINEL_FLAGS=1 as opt-out.
# Pure-CRuby: a stub SPINEL captures its argv, no real compile.
class TestSpinelFlags < Minitest::Test
  TEP_BIN = File.expand_path("../../bin/tep", __dir__)

  def with_project(flags: nil)
    Dir.mktmpdir("tep-flags") do |dir|
      File.write(File.join(dir, "app.rb"), <<~APP)
        get '/' do
          "hi"
        end
      APP
      if flags
        FileUtils.mkdir_p(File.join(dir, "vendor", "spinel", "sig"))
        File.write(File.join(dir, "vendor", "spinel", "spinel-flags"), flags)
      end
      argv_file = File.join(dir, "captured_argv")
      stub = File.join(dir, "spinel-stub")
      File.write(stub, <<~SH)
        #!/bin/sh
        printf '%s\\n' "$@" > #{argv_file}
        exit 0
      SH
      File.chmod(0o755, stub)
      yield dir, stub, argv_file
    end
  end

  def build(dir, stub, env = {})
    out = ""
    IO.popen(env.merge("SPINEL" => stub, "TEP_QUIET" => "1"),
             [RbConfig.ruby, TEP_BIN, "build", File.join(dir, "app.rb"),
              "-o", File.join(dir, "app_bin")],
             err: [:child, :out]) { |io| out = io.read }
    [$?.success?, out]
  end

  def test_flags_applied_with_resolved_relative_path
    with_project(flags: "--rbs vendor/spinel/sig\n") do |dir, stub, argv_file|
      ok, out = build(dir, stub)
      assert ok, "tep build failed: #{out}"
      argv = File.read(argv_file).split("\n")
      i = argv.index("--rbs")
      refute_nil i, "--rbs not passed to spinel: #{argv.inspect}"
      # Relative path in the file resolves against the project root.
      assert_equal File.join(dir, "vendor/spinel/sig"), argv[i + 1]
    end
  end

  def test_no_flags_file_no_extra_args
    with_project(flags: nil) do |dir, stub, argv_file|
      ok, out = build(dir, stub)
      assert ok, "tep build failed: #{out}"
      argv = File.read(argv_file).split("\n")
      refute_includes argv, "--rbs"
    end
  end

  def test_opt_out_env
    with_project(flags: "--rbs vendor/spinel/sig\n") do |dir, stub, argv_file|
      ok, out = build(dir, stub, "TEP_NO_SPINEL_FLAGS" => "1")
      assert ok, "tep build failed: #{out}"
      argv = File.read(argv_file).split("\n")
      refute_includes argv, "--rbs"
    end
  end

  def test_flag_tokens_and_opaque_values_pass_through
    with_project(flags: "--future-flag opaque-value\n") do |dir, stub, argv_file|
      ok, out = build(dir, stub)
      assert ok, "tep build failed: #{out}"
      argv = File.read(argv_file).split("\n")
      i = argv.index("--future-flag")
      refute_nil i
      # No file named opaque-value exists in the project -> untouched.
      assert_equal "opaque-value", argv[i + 1]
    end
  end
end
