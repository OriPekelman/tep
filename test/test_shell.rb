require_relative "helper"

# Tep::Shell -- popen + read. Lives behind FFI helpers
# (sphttp_shell_capture, sphttp_file_read); this test boots a tiny
# tep app that exercises both from inside a handler.
class TestShell < TepTest
  app_source <<~RB
    require 'sinatra'

    get '/echo' do
      Tep::Shell.run("printf hello").strip
    end

    get '/run_limited' do
      # Cap at 3 bytes; full output is "hello" -- we should see "hel".
      Tep::Shell.run_limited("printf hello", 3)
    end

    get '/file' do
      # /etc/hostname is small, ASCII, present on Linux + macOS.
      Tep::Shell.read("/etc/hostname").length.to_s
    end

    get '/missing' do
      Tep::Shell.read("/does/not/exist/at/all").length.to_s
    end
  RB

  def test_run_captures_stdout
    res = get("/echo")
    assert_equal "200", res.code
    assert_equal "hello", res.body.strip
  end

  def test_run_respects_byte_cap
    res = get("/run_limited")
    assert_equal "200", res.code
    assert_equal "hel", res.body
  end

  def test_read_returns_bytes_for_real_file
    res = get("/file")
    assert_equal "200", res.code
    # /etc/hostname is at least 1 byte (the name + newline).
    assert_operator res.body.strip.to_i, :>=, 1
  end

  def test_read_returns_empty_on_missing_path
    res = get("/missing")
    assert_equal "200", res.code
    assert_equal "0", res.body.strip
  end
end
