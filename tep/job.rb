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
#     result      TEXT,
#     attempts    INTEGER,   -- times claimed so far
#     max_retries INTEGER,   -- retries allowed after the first attempt
#     run_at      INTEGER,   -- not claimable before this epoch second
#     started_at  INTEGER,   -- when the current attempt was claimed
#     error       TEXT       -- last failure message
#   )
#
# `init_schema` creates the table, and on a table made by an older
# tep it adds the last five columns with ALTER TABLE.
#
# The single-arg payload is intentional: structured data goes
# through JSON (Tep::Json) which we already ship. Sidekiq's
# multi-arg `perform_async(a, b, c)` translates to encoding the
# tuple as a JSON string and decoding it in `perform`.
#
# Retries and delay (#230)
# ------------------------
#   Tep::Job.enqueue(name, arg, db)                    # run now, no retry
#   Tep::Job.enqueue_in(seconds, name, arg, db)        # sidekiq perform_in
#   Tep::Job.enqueue_opts(name, arg, db, delay, max_retries)
#
# A worker that catches a failure calls
#
#   Tep::Job.retry_or_fail(db, row_id, "message")
#
# which requeues the job with sidekiq's backoff (attempts**4 + 15
# seconds) while retries remain, and otherwise marks it `failed`.
# Either way the message lands in the `error` column. `mark_failed`
# is the unconditional terminal form.
#
# A worker that dies mid-job leaves its row `running`. Reclaim those
# with `Tep::Job.requeue_stale(db, older_than_seconds)`.
#
# API
# ---
# Define a job by subclassing Tep::Job and overriding `perform`:
#
#     class HelloJob < Tep::Job
#       def perform(arg)
#         SpinelKit::Log.new.info("hello " + arg)
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
#       begin
#         if name == "HelloJob"
#           result = HelloJob.new.perform(arg)
#         end
#         Tep::Job.mark_done(DB_PATH, row_id, result)
#       rescue => e
#         Tep::Job.retry_or_fail(DB_PATH, row_id, e.message)
#       end
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

    # Columns added after the first release of the table, in the
    # order `init_schema` migrates them.
    def self.added_columns
      ["attempts INTEGER DEFAULT 0", "max_retries INTEGER DEFAULT 0",
       "run_at INTEGER DEFAULT 0", "started_at INTEGER DEFAULT 0",
       "error TEXT DEFAULT ''"]
    end

    # Idempotent. Creates the queue table if missing, and adds the
    # retry/delay columns to a table created by an older tep. Pass
    # the same SQLite path to enqueue / fetch_next / mark_done.
    def self.init_schema(db_path)
      db = Tep::SQLite.new
      if db.open(db_path)
        db.exec("PRAGMA busy_timeout = 2000")
        db.exec("CREATE TABLE IF NOT EXISTS tep_jobs (" +
                "id INTEGER PRIMARY KEY, " +
                "job_name TEXT, arg TEXT, status TEXT, " +
                "created_at INTEGER, finished_at INTEGER, result TEXT, " +
                "attempts INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 0, " +
                "run_at INTEGER DEFAULT 0, started_at INTEGER DEFAULT 0, " +
                "error TEXT DEFAULT '')")
        cols = Job.added_columns
        i = 0
        while i < cols.length
          col = cols[i]
          name = col.split(" ")[0]
          have = db.first_int("SELECT COUNT(*) FROM pragma_table_info('tep_jobs') WHERE name = ?", name)
          if have == 0
            db.exec("ALTER TABLE tep_jobs ADD COLUMN " + col)
          end
          i += 1
        end
        db.close
      end
      0
    end

    # Append a `queued` row that is claimable now and is not retried.
    # Returns the new row id (0 on DB error).
    def self.enqueue(name, arg, db_path)
      Job.enqueue_opts(name, arg, db_path, 0, 0)
    end

    # Sidekiq's `perform_in`: claimable `seconds` from now.
    def self.enqueue_in(seconds, name, arg, db_path)
      Job.enqueue_opts(name, arg, db_path, seconds, 0)
    end

    # The general form. `delay_seconds` postpones the first attempt;
    # `max_retries` is how many times `retry_or_fail` requeues the job
    # after its first attempt. Returns the new row id (0 on DB error).
    def self.enqueue_opts(name, arg, db_path, delay_seconds, max_retries)
      db = Tep::SQLite.new
      if !db.open(db_path)
        return 0
      end
      db.exec("PRAGMA busy_timeout = 2000")
      now = Time.now.to_i
      db.prepare("INSERT INTO tep_jobs (job_name, arg, status, created_at, attempts, max_retries, run_at, started_at, error) VALUES (?, ?, 'queued', ?, 0, ?, ?, 0, '')")
      db.bind_str(1, name)
      db.bind_str(2, arg)
      db.bind_int(3, now)
      db.bind_int(4, max_retries)
      db.bind_int(5, now + delay_seconds)
      db.step
      db.finalize
      id = db.last_rowid
      db.close
      id
    end

    # Claim the oldest `queued` row whose `run_at` has passed and mark
    # it `running`. Returns "row_id|name|arg" packed into one string
    # (the caller splits on "|" with limit 3), or "" if nothing is
    # claimable / the DB errored. The row_id is needed for the matching
    # `mark_done` / `retry_or_fail` call. Caller is responsible for
    # dispatching to the right subclass.
    #
    # The claim is ONE statement (UPDATE ... RETURNING), so two workers
    # draining the same file can never claim the same row. It used to
    # be a SELECT followed by a separate UPDATE.
    def self.fetch_next(db_path)
      db = Tep::SQLite.new
      if !db.open(db_path)
        return ""
      end
      db.exec("PRAGMA busy_timeout = 2000")
      now = Time.now.to_i
      db.prepare("UPDATE tep_jobs SET status = 'running', attempts = attempts + 1, started_at = ? " +
                 "WHERE id = (SELECT id FROM tep_jobs WHERE status = 'queued' AND run_at <= ? ORDER BY id ASC LIMIT 1) " +
                 "RETURNING id, job_name, arg")
      db.bind_int(1, now)
      db.bind_int(2, now)
      out = ""
      if db.step == 1
        row_id   = db.col_int(0)
        job_name = db.col_str(1)
        arg      = db.col_str(2)
        out = row_id.to_s + "|" + job_name + "|" + arg
      end
      db.finalize
      db.close
      out
    end

    # Mark the row `done` and store the result string.
    def self.mark_done(db_path, row_id, result)
      db = Tep::SQLite.new
      if !db.open(db_path)
        return 0
      end
      db.exec("PRAGMA busy_timeout = 2000")
      db.prepare("UPDATE tep_jobs SET status = 'done', finished_at = ?, result = ? WHERE id = ?")
      db.bind_int(1, Time.now.to_i)
      db.bind_str(2, result)
      db.bind_int(3, row_id)
      db.step
      db.finalize
      db.close
      1
    end

    # Record a failed attempt. While the job has retries left it goes
    # back to `queued` with sidekiq's backoff (attempts**4 + 15 seconds
    # from now); otherwise it becomes `failed`. The message is stored
    # in `error` either way. Returns 1 if the job was requeued, 0 if it
    # is now terminally failed (or on a DB error).
    def self.retry_or_fail(db_path, row_id, error)
      db = Tep::SQLite.new
      if !db.open(db_path)
        return 0
      end
      db.exec("PRAGMA busy_timeout = 2000")
      now = Time.now.to_i
      db.prepare("UPDATE tep_jobs SET " +
                 "status = CASE WHEN attempts <= max_retries THEN 'queued' ELSE 'failed' END, " +
                 "run_at = CASE WHEN attempts <= max_retries THEN ? + attempts * attempts * attempts * attempts + 15 ELSE run_at END, " +
                 "finished_at = CASE WHEN attempts <= max_retries THEN finished_at ELSE ? END, " +
                 "error = ? WHERE id = ? RETURNING status")
      db.bind_int(1, now)
      db.bind_int(2, now)
      db.bind_str(3, error)
      db.bind_int(4, row_id)
      requeued = 0
      if db.step == 1
        if db.col_str(0) == "queued"
          requeued = 1
        end
      end
      db.finalize
      db.close
      requeued
    end

    # Put `running` rows claimed more than `older_than_seconds` ago
    # back in the queue: their worker died before marking them. The
    # attempt already counted, so a job out of retries fails instead.
    # Returns 1 on success, 0 on a DB error.
    def self.requeue_stale(db_path, older_than_seconds)
      db = Tep::SQLite.new
      if !db.open(db_path)
        return 0
      end
      db.exec("PRAGMA busy_timeout = 2000")
      now = Time.now.to_i
      db.prepare("UPDATE tep_jobs SET " +
                 "status = CASE WHEN attempts <= max_retries THEN 'queued' ELSE 'failed' END, " +
                 "finished_at = CASE WHEN attempts <= max_retries THEN finished_at ELSE ? END, " +
                 "error = 'worker lost' " +
                 "WHERE status = 'running' AND started_at <= ?")
      db.bind_int(1, now)
      db.bind_int(2, now - older_than_seconds)
      db.step
      db.finalize
      db.close
      1
    end

    # Mark the row `failed` unconditionally, without touching `error`.
    # Use `retry_or_fail` to honour retries and record a message.
    def self.mark_failed(db_path, row_id)
      db = Tep::SQLite.new
      if !db.open(db_path)
        return 0
      end
      db.exec("PRAGMA busy_timeout = 2000")
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
