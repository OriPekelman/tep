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

    # Read a file's contents (up to DEFAULT_MAX). Useful for
    # /proc/loadavg, /proc/meminfo, /sys/class/thermal/.../temp,
    # and similar small-text endpoints. Returns "" on open failure.
    #
    # The `+ ""` forces a Ruby-side string copy: the C helper
    # returns a pointer to a static buffer that gets clobbered on
    # the next call, so two consecutive `Tep::Shell.read` calls
    # without the dup would both end up returning the *latest*
    # read's bytes (each :str return from FFI is a raw const
    # char *, not a Ruby-owned copy).
    def self.read(path)
      Sock.sphttp_file_read(path, DEFAULT_MAX) + ""
    end

    def self.read_limited(path, max_bytes)
      Sock.sphttp_file_read(path, max_bytes) + ""
    end

    # Write `data` to `path` atomically (truncate + rewrite).
    # Returns the byte count written, or -1 on failure.
    def self.write(path, data)
      Sock.sphttp_file_write(path, data)
    end
  end
end
