# Tep::Logger -- minimal levelled logger for spinel-AOT'd apps.
#
# Why bundle one? CRuby's stdlib `Logger` is metaprogrammed (the
# severity dispatch loop, the formatter API, the device-rotation
# logic) and doesn't compile through spinel. Most app code that
# wants logging really wants three things: a level guard, a
# formatted line, and a destination.
#
# Surface
# -------
#
#   logger = Tep::Logger.new
#   logger.set_level("info")        # one of: debug / info / warn / error
#   logger.info("server up on " + port.to_s)
#   logger.error("db connect failed")
#
#   # File output: appends to the path. Leave unset for stderr.
#   logger.to_file("/var/log/tep.log")
#
# Each line is `[<unix_seconds>] [<level>] <message>`. The
# integer-seconds timestamp is what spinel exposes from `Time.now`;
# wider strftime support would need a C-shim (defer until callers
# ask for it).
module Tep
  class Logger
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
      Logger.level_value(level) >= Logger.level_value(@min_level)
    end

    # Class-side helper so the comparison stays a pure function and
    # spinel pins its arg type to :str cleanly via the type-seed in
    # tep.rb.
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
      # Unknown level -- treat as info so misspelled labels don't
      # vanish silently.
      1
    end

    def format_line(level, msg)
      "[" + Time.now.to_i.to_s + "] [" + level + "] " + msg
    end
  end
end
