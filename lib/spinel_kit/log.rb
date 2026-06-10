# VENDORED from OriPekelman/spinelkit @ 09e8558 -- DO NOT EDIT HERE.
# Edit upstream and re-sync with `make vendor-spinelkit`.
# SpinelKit::Log -- minimal levelled logger for spinel-AOT'd apps.
#
# WHY THIS EXISTS. CRuby's stdlib `Logger` is metaprogrammed (the severity
# dispatch loop, the formatter API, the device-rotation logic) and the
# spinelgems catalog rejects it (unresolved calls). Most app code that wants
# logging really wants three things: a level guard, a formatted line, and a
# destination. Ported verbatim from Tep::Logger; toy gains it for free.
#
# Surface
# -------
#   logger = SpinelKit::Log.new
#   logger.set_level("info")        # one of: debug / info / warn / error
#   logger.info("server up on " + port.to_s)
#   logger.error("db connect failed")
#
#   # File output: appends to the path. Leave unset for stderr.
#   logger.to_file("/var/log/app.log")
#
# Each line is `[<unix_seconds>] [<level>] <message>`. The integer-seconds
# timestamp is what spinel exposes from `Time.now`; wider strftime support
# would need a C-shim (defer until callers ask for it).
#
# SPINEL NAMING DISCIPLINE: the method/param names below are the donor's
# proven-green spellings; the class-side `level_value` keeps the comparison
# a pure function so spinel pins its arg type to :str cleanly via a consumer
# type-seed. See docs/spinel-discipline.md.
module SpinelKit
  class Log
    attr_accessor :min_level, :file_path

    def initialize
      @min_level = "info"
      @file_path = ""
    end

    def set_level(name); @min_level = name; end
    def to_file(path);   @file_path = path; end
    def to_stderr;       @file_path = ""; end

    def debug(msg); log("debug", msg); end
    def info(msg);  log("info",  msg); end
    def warn(msg);  log("warn",  msg); end
    def error(msg); log("error", msg); end

    def log(level, msg)
      if !should_log?(level)
        return
      end
      line = format_line(level, msg)
      if @file_path.length > 0
        File.open(@file_path, "a") do |f|
          f.puts(line)
        end
      else
        $stderr.puts(line)
      end
    end

    def should_log?(level)
      Log.level_value(level) >= Log.level_value(@min_level)
    end

    # Class-side helper so the comparison stays a pure function and spinel
    # pins its arg type to :str cleanly via a consumer-side type-seed.
    def self.level_value(name)
      if name == "debug"
        return 0
      end
      if name == "info"
        return 1
      end
      if name == "warn"
        return 2
      end
      if name == "error"
        return 3
      end
      # Unknown level -- treat as info so misspelled labels don't vanish
      # silently.
      1
    end

    def format_line(level, msg)
      "[" + Time.now.to_i.to_s + "] [" + level + "] " + msg
    end
  end
end
