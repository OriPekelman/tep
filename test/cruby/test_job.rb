require_relative "helper"

# Tep::Job -- SQLite-backed sidekiq-shaped queue. The app declares
# job classes, enqueues from one handler, then drains via fetch_next
# from another. Dispatch is user-side (spinel can't carry cls_id
# through PtrArray<Tep::Job>), so the worker handler has an explicit
# `if name == "..."` ladder.
class TestJob < TepTest
  app_source <<~RB
    require 'sinatra'

    DB_PATH = "/tmp/tep_job_test.db"

    on_start do
      Tep::Shell.run("rm -f " + DB_PATH)
      Tep::Job.init_schema(DB_PATH)
    end

    class UpcaseJob < Tep::Job
      def perform(arg)
        arg.upcase
      end
    end

    class ReverseJob < Tep::Job
      def perform(arg)
        out = ""
        i = arg.length - 1
        while i >= 0
          out = out + arg[i]
          i -= 1
        end
        out
      end
    end

    get '/enqueue/:name/:arg' do
      id = Tep::Job.enqueue(params[:name], params[:arg], DB_PATH)
      "id=" + id.to_s
    end

    get '/process' do
      claim = Tep::Job.fetch_next(DB_PATH)
      if claim.length == 0
        "ran=0"
      else
        parts  = claim.split("|", 3)
        row_id = parts[0].to_i
        name   = parts[1]
        arg    = parts[2]
        result = ""
        if name == "UpcaseJob"
          result = UpcaseJob.new.perform(arg)
        elsif name == "ReverseJob"
          result = ReverseJob.new.perform(arg)
        end
        Tep::Job.mark_done(DB_PATH, row_id, result)
        "ran=1"
      end
    end

    get '/result/:id' do
      db = Tep::SQLite.new
      db.open(DB_PATH)
      st   = db.first_str("SELECT status FROM tep_jobs WHERE id = ?", params[:id])
      body = db.first_str("SELECT result FROM tep_jobs WHERE id = ?", params[:id])
      db.close
      st + "/" + body
    end
  RB

  def test_upcase_job_round_trip
    enq = get("/enqueue/UpcaseJob/hello")
    assert_match(/id=\d+/, enq.body)
    id = enq.body.split("=")[1]

    pr = get("/process")
    assert_equal "ran=1", pr.body

    rr = get("/result/#{id}")
    assert_equal "done/HELLO", rr.body
  end

  def test_reverse_job_round_trip
    enq = get("/enqueue/ReverseJob/tepworks")
    id  = enq.body.split("=")[1]
    get("/process")
    rr = get("/result/#{id}")
    assert_equal "done/skrowpet", rr.body
  end

  def test_process_returns_zero_on_empty_queue
    20.times { get("/process") }
    res = get("/process")
    assert_equal "ran=0", res.body
  end

  def test_fifo_order
    a = get("/enqueue/UpcaseJob/aaa").body.split("=")[1]
    b = get("/enqueue/UpcaseJob/bbb").body.split("=")[1]
    get("/process")
    get("/process")
    ra = get("/result/#{a}").body
    rb = get("/result/#{b}").body
    assert_equal "done/AAA", ra
    assert_equal "done/BBB", rb
  end
end
