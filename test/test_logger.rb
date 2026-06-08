require_relative "helper"

# SpinelKit::Log -- levelled logger with stderr / file output.
class TestLogger < TepTest
  TMP_LOG = "/tmp/tep_logger_test_#{$$}.log"

  app_source <<~RB
    require 'sinatra'

    LOGGER = SpinelKit::Log.new
    LOGGER.set_level("debug")
    LOGGER.to_file("#{TMP_LOG}")

    before do
      LOGGER.info(req.verb + " " + req.path)
    end

    get '/dbg' do
      LOGGER.debug("dbg-line")
      "ok"
    end

    get '/info' do
      LOGGER.info("info-line")
      "ok"
    end

    get '/warn' do
      LOGGER.warn("warn-line")
      "ok"
    end

    get '/err' do
      LOGGER.error("err-line")
      "ok"
    end

    get '/clear' do
      File.write("#{TMP_LOG}", "")
      "cleared"
    end

    # Toggle level at runtime.
    get '/level/:lvl' do
      LOGGER.set_level(params[:lvl])
      "level=" + params[:lvl]
    end
  RB

  Minitest.after_run do
    File.unlink(TMP_LOG) if File.exist?(TMP_LOG)
  end

  def read_log
    File.exist?(TMP_LOG) ? File.read(TMP_LOG) : ""
  end

  def clear_log
    get("/clear")
  end

  def setup
    super
    # Tests run in randomised order against a single booted app
    # that shares LOGGER state. Reset level + clear log per test.
    get("/level/debug")
    clear_log
  end

  def test_each_level_writes_a_line
    get("/dbg")
    get("/info")
    get("/warn")
    get("/err")
    log = read_log
    assert_match(/\[debug\] dbg-line/, log)
    assert_match(/\[info\] info-line/, log)
    assert_match(/\[warn\] warn-line/, log)
    assert_match(/\[error\] err-line/, log)
  end

  def test_level_filter_drops_below_threshold
    get("/level/warn")
    clear_log    # drop the "/level/warn" before-filter line too
    get("/dbg")
    get("/info")
    get("/warn")
    get("/err")
    log = read_log
    refute_match(/\[debug\]/, log)
    refute_match(/\[info\]/, log)
    assert_match(/\[warn\] warn-line/, log)
    assert_match(/\[error\] err-line/, log)
  end

  def test_format_includes_unix_timestamp
    get("/info")
    log = read_log
    assert_match(/\A\[\d+\] \[info\]/, log)
  end
end
