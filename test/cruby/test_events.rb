require_relative "helper"
require "json"

# Tep::Events -- toy/v1 JSONL emitter. The app emits a full
# run_start -> inference x2 -> run_end scenario into a file and dumps
# it back over HTTP, so the test can parse + assert the envelope.
class TestEvents < TepTest
  EV_PATH = "/tmp/tep_events_test.jsonl"

  app_source <<~RB
    require 'sinatra'

    PATH = "#{EV_PATH}"

    # One self-contained scenario: reset the file, emit the full
    # event sequence, return the raw JSONL.
    get '/scenario' do
      File.write(PATH, "")
      ev = Tep::Events.new(PATH)
      ev.run_start("testhost", "cpu", "smollm2-135m", "/m.gguf",
                   "{\\"server\\":\\"tep\\",\\"cap\\":\\"infer\\"}")
      ev.inference("smollm2-135m", 12, 8, 87000,
                   "{\\"request_id\\":\\"cmpl-abc\\",\\"principal_id\\":\\"user:42\\"}")
      ev.inference("smollm2-135m", 5, 3, 40000,
                   "{\\"request_id\\":\\"cmpl-def\\"}")
      ev.run_end("ok")
      File.read(PATH)
    end

    # Disabled emitter ("" path): enabled? false + no file written.
    get '/disabled' do
      File.write(PATH, "SENTINEL")
      d = Tep::Events.new("")
      d.run_start("h", "cpu", "m", "/p", "{}")
      d.inference("m", 1, 1, 1, "{}")
      d.run_end("ok")
      # File must still hold the sentinel (disabled wrote nothing).
      "enabled=" + d.enabled?.to_s + " file=" + File.read(PATH)
    end

    # ISO-8601 helper directly.
    get '/iso' do
      Sock.sphttp_iso8601_utc(0)
    end
  RB

  def scenario_lines
    body = get("/scenario").body
    body.split("\n").reject(&:empty?).map { |l| JSON.parse(l) }
  end

  def test_emits_four_events_in_order
    lines = scenario_lines
    assert_equal 4, lines.length
    assert_equal "run_start", lines[0]["kind"]
    # #136: inference events are kind:"eval"+name:"request".
    assert_equal "eval",      lines[1]["kind"]
    assert_equal "request",   lines[1]["name"]
    assert_equal "eval",      lines[2]["kind"]
    assert_equal "request",   lines[2]["name"]
    assert_equal "run_end",   lines[3]["kind"]
  end

  def test_run_start_envelope
    rs = scenario_lines[0]
    assert_equal "toy/v1", rs["schema"]
    assert_equal 0, rs["t"]
    # host is {name, os, arch} per toy/v1 (#115).
    assert_equal "testhost", rs["host"]["name"]
    assert_kind_of String, rs["host"]["os"]
    assert_kind_of String, rs["host"]["arch"]
    refute_empty rs["host"]["os"], "os field should be populated via uname()"
    refute_empty rs["host"]["arch"], "arch field should be populated via uname()"
    assert_equal "cpu", rs["backend"]["kind"]
    assert_equal "smollm2-135m", rs["model"]["name"]
    assert_equal "/m.gguf", rs["model"]["path"]
    assert_equal "infer", rs["config"]["cap"]
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, rs["started_at"])
  end

  def test_inference_event_fields
    ev = scenario_lines[1]
    # #136 spec shape: kind:"eval" + phase:"serve" + name:"request",
    # with model + tokens + latency_us nested under extra.
    assert_equal "eval",    ev["kind"]
    assert_equal "serve",   ev["phase"]
    assert_equal "request", ev["name"]
    assert_kind_of Integer, ev["t"]
    assert_equal "smollm2-135m", ev["extra"]["model"]
    assert_equal 12,      ev["extra"]["prompt_tokens"]
    assert_equal 8,       ev["extra"]["completion_tokens"]
    assert_equal 87000,   ev["extra"]["latency_us"]
    assert_equal "cmpl-abc", ev["extra"]["request_id"]
    assert_equal "user:42",  ev["extra"]["principal_id"]
  end

  def test_run_end_stats_accumulate
    re = scenario_lines[3]
    assert_equal "ok", re["reason"]
    assert_equal 2, re["stats"]["requests"]      # two inference calls
    assert_equal 11, re["stats"]["tokens_out"]   # 8 + 3
    assert_equal 0, re["stats"]["errors"]
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, re["ended_at"])
  end

  def test_disabled_emitter_writes_nothing
    res = get("/disabled")
    assert_equal "enabled=false file=SENTINEL", res.body
  end

  def test_iso8601_epoch_zero
    assert_equal "1970-01-01T00:00:00Z", get("/iso").body
  end
end
