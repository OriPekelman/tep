# Tep::Job -- sidekiq-shaped background jobs over a SQLite queue.
#
# Why a queue at all?
# -------------------
# Tep::Parallel covers synchronous fan-out within one request. Some
# work doesn't fit: it's too slow to inline (an LLM call), needs to
# survive the request lifetime (a follow-up email), or should run
# on a cron-like cadence (refresh a cached snapshot). For those,
# you want sidekiq's shape: enqueue from anywhere, a separate
# worker process drains the queue.
#
# Storage
# -------
# SQLite, in a table the framework creates on demand:
#
#   CREATE TABLE tep_jobs (
#     id          INTEGER PRIMARY KEY,
#     job_name    TEXT,      -- registered class identifier
#     arg         TEXT,      -- single string payload
#     status      TEXT,      -- queued|running|done|failed
#     created_at  INTEGER,
#     finished_at INTEGER,
#     result      TEXT
#   )
#
# The single-arg payload is intentional: structured data goes
# through JSON (Tep::Json) which we already ship. Sidekiq's
# multi-arg `perform_async(a, b, c)` translates to encoding the
# tuple as a JSON string and decoding it in `perform`.
#
# API
# ---
# Define a job by subclassing Tep::Job and overriding `perform`:
#
#     class HelloJob < Tep::Job
#       def perform(arg)
#         Tep::Logger.new.info("hello " + arg)
#         "done"
#       end
#     end
#
# Enqueue from anywhere:
#
#     Tep::Job.enqueue("HelloJob", "world", DB_PATH)
#
# Worker side: fetch one, dispatch, mark done. The dispatch is
# user-written because spinel doesn't carry cls_id tags through
# `PtrArray<Tep::Job>`, so the framework can't virtual-dispatch
# `handler.perform(arg)` to the right subclass on its own.
#
#     loop do
#       claim = Tep::Job.fetch_next(DB_PATH)  # "" if empty, else
#                                             # "row_id|name|arg"
#       break if claim.length == 0
#       parts  = claim.split("|", 3)
#       row_id = parts[0].to_i
#       name   = parts[1]
#       arg    = parts[2]
#       result = ""
#       if name == "HelloJob"
#         result = HelloJob.new.perform(arg)
#       end
#       Tep::Job.mark_done(DB_PATH, row_id, result)
#     end
#
# The verbosity of the `if name == "..."` ladder is the price of
# type safety in spinel. A future bin/tep pass could generate this
# dispatcher from the set of `Tep::Job` subclasses at compile time
# (mirroring the way routes are generated from `get '/x' do .. end`),
# at which point this surface becomes a one-liner. For v0.5 the
# manual ladder is fine -- a single tep app rarely has more than
# a handful of distinct job classes.
#
# Comparison to sidekiq
# ---------------------
# Sidekiq's `MyJob.perform_async(x)` enqueues on a Redis list keyed
# by class name. We do the same with SQLite + an explicit name
# string. The `Tep::Job` subclass + `perform(arg)` shape stays;
# only the worker drain loop differs (sidekiq does the dispatch via
# Ruby's `Object.const_get`, which spinel can't lower).
module Tep
  class Job
    # Subclasses override. The default uses `arg` as :str so spinel's
    # analyzer pins the param type rather than defaulting to :int
    # for an unused parameter -- otherwise subclass `arg.upcase` calls
    # fail to resolve against an int-typed slot.
    def perform(arg)
      "" + arg
    end

    # Idempotent. Creates the queue table if missing. Pass the same
    # SQLite path to enqueue / fetch_next / mark_done.
    def self.init_schema(db_path)
      db = Tep::SQLite.new
      if db.open(db_path)
        db.exec("CREATE TABLE IF NOT EXISTS tep_jobs (" +
                "id INTEGER PRIMARY KEY, " +
                "job_name TEXT, arg TEXT, status TEXT, " +
                "created_at INTEGER, finished_at INTEGER, result TEXT)")
        db.close
      end
      0
    end

    # Append a `queued` row. Returns the new row id (0 on DB error).
    def self.enqueue(name, arg, db_path)
      db = Tep::SQLite.new
      if !db.open(db_path)
        return 0
      end
      db.prepare("INSERT INTO tep_jobs (job_name, arg, status, created_at) VALUES (?, ?, ?, ?)")
      db.bind_str(1, name)
      db.bind_str(2, arg)
      db.bind_str(3, "queued")
      db.bind_int(4, Time.now.to_i)
      db.step
      db.finalize
      id = db.last_rowid
      db.close
      id
    end

    # Claim the oldest `queued` row and mark it `running`. Returns
    # "row_id|name|arg" packed into one string (the caller splits on
    # "|" with limit 3), or "" if the queue is empty / errored. The
    # row_id is needed for the matching `mark_done` call. Caller is
    # responsible for dispatching to the right subclass and then
    # writing the result back via `mark_done`.
    def self.fetch_next(db_path)
      db = Tep::SQLite.new
      if !db.open(db_path)
        return ""
      end
      db.prepare("SELECT id, job_name, arg FROM tep_jobs WHERE status = 'queued' ORDER BY id ASC LIMIT 1")
      out = ""
      if db.step == 1
        row_id   = db.col_int(0)
        job_name = db.col_str(1)
        arg      = db.col_str(2)
        out = row_id.to_s + "|" + job_name + "|" + arg
      end
      db.finalize
      if out.length > 0
        db.prepare("UPDATE tep_jobs SET status = 'running' WHERE id = ?")
        db.bind_int(1, row_id)
        db.step
        db.finalize
      end
      db.close
      out
    end

    # Mark the row `done` with an empty result. Use `write_result`
    # if you want to attach a result string -- a spinel issue with
    # cross-class parameter widening (the followup to #429) means a
    # cmeth that takes a String param sourced from a virtual or
    # cross-class dispatch loses the :str type at the cmeth signature,
    # breaking the bind_str body. Until that lands upstream, the user
    # writes the result via direct SQLite calls in their own handler;
    # this method just flips the row status.
    def self.mark_done(db_path, row_id)
      db = Tep::SQLite.new
      if !db.open(db_path)
        return 0
      end
      db.prepare("UPDATE tep_jobs SET status = 'done', finished_at = ? WHERE id = ?")
      db.bind_int(1, Time.now.to_i)
      db.bind_int(2, row_id)
      db.step
      db.finalize
      db.close
      1
    end

    # Mark the row `failed`. Same caveat as `mark_done`: the error
    # message is not stored by this method; the user writes it via
    # their own SQLite calls if they want it persisted.
    def self.mark_failed(db_path, row_id)
      db = Tep::SQLite.new
      if !db.open(db_path)
        return 0
      end
      db.prepare("UPDATE tep_jobs SET status = 'failed', finished_at = ? WHERE id = ?")
      db.bind_int(1, Time.now.to_i)
      db.bind_int(2, row_id)
      db.step
      db.finalize
      db.close
      1
    end
  end
end
