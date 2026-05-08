# Tep::Response -- what the handler writes back. Headers are a Bag
# (string-keyed); the framework adds Content-Length / Connection
# automatically when serializing.
module Tep
  class Response
    attr_accessor :status, :headers, :body, :halted, :file_path

    def initialize
      @status    = 200
      @headers   = Tep.str_hash
      @body      = ""
      @halted    = false
      @file_path = ""
    end

    def send_file(path)
      @file_path = path
      @body = ""
    end

    # Spinel's polymorphic-receiver write codegen emits a no-op for
    # `res.body = x` when called from a context that has a poly
    # value, so we force the assignment through this method (where
    # `self` is unambiguously Response).
    def set_body_if_empty(s)
      if @body.length == 0 && s.length > 0
        @body = s
      end
    end

    def set_status(n); @status = n; end

    def halted_close?
      @halted && @status >= 300
    end
  end
end
