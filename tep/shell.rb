# Tep::Shell -- minimal popen-based shell-out + /proc-style file
# reads. The pair covers ~all of what a "system dashboard" needs
# without dragging in an Open3-equivalent.
#
# Security note
# -------------
# `run(cmd)` passes its argument verbatim to `/bin/sh -c`. NEVER
# interpolate untrusted input into the command string -- you'll get
# a textbook command injection. The same is true of every other
# popen-style API in any language; we don't pretend otherwise.
#
# When you need to feed user-controllable values to a command, build
# the argv yourself, write to a temp file, or use an explicit allow-
# list of acceptable inputs.
module Tep
  class Shell
    DEFAULT_MAX = 65535

    # Run `cmd` via /bin/sh -c; return up to DEFAULT_MAX bytes of
    # stdout as a string. Stderr is inherited (visible on the
    # server's console / log). The command's exit status is
    # discarded -- callers that need it can append `; echo "EX=$?"`
    # and parse the tail.
    # `+ ""` forces a Ruby-side copy of the static C buffer; see
    # `read` below.
    def self.run(cmd)
      Sock.sphttp_shell_capture(cmd, DEFAULT_MAX) + ""
    end

    # As above but with a caller-chosen byte cap. Lower caps are
    # cheaper memory-wise; higher caps (up to the sphttp internal
    # buffer of ~64KB) let longer outputs through.
    def self.run_limited(cmd, max_bytes)
      Sock.sphttp_shell_capture(cmd, max_bytes) + ""
    end

    # Read a file's contents. Useful for /proc/loadavg, /proc/meminfo,
    # /sys/class/thermal/.../temp, and similar small-text endpoints.
    # Returns "" on open failure. Spinel's File.read now raises a
    # CRuby-correct Errno on a missing/unreadable path (it used to
    # silently return ""); we rescue here to preserve this helper's
    # never-raise contract -- a handler reading /proc should get "" for
    # an absent file, not a 502'd worker.
    def self.read(path)
      begin
        File.read(path)
      rescue => e
        ""
      end
    end

    # Bounded read: slice after the fact. The cap is mostly a
    # defensive cue -- callers that need it should be reading
    # bounded /proc files anyway. Same never-raise contract as #read.
    def self.read_limited(path, max_bytes)
      out = ""
      begin
        out = File.read(path)
      rescue => e
        out = ""
      end
      out.length > max_bytes ? out[0, max_bytes] : out
    end

    # Write `data` to `path` (truncate + rewrite). Returns the byte
    # count for symmetry with the old FFI shape; spinel's File.write
    # is void, so we recover it from data.length.
    def self.write(path, data)
      File.write(path, data)
      data.length
    end
  end
end
