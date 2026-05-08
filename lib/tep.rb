# Tep -- a Sinatra-flavoured framework that compiles to a native
# binary via Spinel.
#
#   require_relative "../tep/lib/tep"
#
#   class Root < Tep::Handler
#     def handle(req, res)
#       "<h1>hello, world</h1>"
#     end
#   end
#   Tep.get "/", Root.new
#
#   Tep.run!(4567, 1)
#
# Sinatra-classic source (with `do ... end` blocks) is supported via
# `bin/tep build app.rb`, which translates blocks into Handler
# subclasses before invoking spinel.

require_relative "tep/version"
require_relative "tep/url"
require_relative "tep/net"
require_relative "tep/session"
require_relative "tep/request"
require_relative "tep/response"
require_relative "tep/handler"
require_relative "tep/filter"
require_relative "tep/streamer"
require_relative "tep/parser"
require_relative "tep/router"
require_relative "tep/app"
require_relative "tep/server"

module Tep
  # Helper: spinel won't infer types on an empty `{}`, so we seed
  # with one entry then delete it. Used by Request/Response so
  # users get the natural Hash[] / Hash[]= surface (Sinatra-style
  # `params["name"]` works without a bespoke Bag wrapper).
  def self.str_hash
    h = {"" => ""}
    h.delete("")
    h
  end

  # Session signing secret. Empty by default, which disables session
  # writes (the Set-Cookie path no-ops). Set at app load time:
  #
  #   Tep.session_secret = ENV.fetch("TEP_SESSION_SECRET")
  #
  # Stored on the APP instance (spinel doesn't reliably type-track
  # module-level `@@cvars` or globals).

  APP = App.new

  def self.session_secret;     APP.session_secret;        end
  def self.session_secret=(v); APP.set_session_secret(v); end

  # Spinel infers method parameter types from concrete call sites.
  # If a user app never calls Tep.before / Tep.not_found / etc.,
  # spinel falls back to int and the underlying set_* assignment
  # mismatches the typed ivar. Force-calling each setter here with
  # the canonical default ensures the parameter type is locked in
  # regardless of which DSL methods the user app actually invokes.
  APP.set_static_root("")
  APP.set_before(Filter.new)
  APP.set_after(Filter.new)
  APP.set_not_found(Handler.new)
  # Type-seeding: methods that may not be called by a given user app
  # would otherwise default their param C types to mrb_int and
  # mismatch the typed ivars they touch.
  _tep_seed_res = Response.new
  _tep_seed_res.set_cookie("", "", str_hash)
  APP.set_session_secret("")
  _tep_seed_sess = Session.new
  _tep_seed_sess.load_from("", "")
  _tep_seed_sess.to_cookie_value("")
  _tep_seed_sess.set("a", "")
  _tep_seed_sess.get("a")
  _tep_seed_sess.has?("a")
  _tep_seed_res.start_stream(Streamer.new)
  _tep_seed_stream = Stream.new(0)
  _tep_seed_res.streamer.pump(_tep_seed_stream)
  _tep_seed_stream.write("")   # pin the parameter type to :str

  # ---------------- DSL ----------------
  # Spinel emits every defined method whether called or not, and
  # infers parameter types from concrete call sites; methods nobody
  # calls fall back to int parameters that mismatch the typed ivars
  # they assign. So the v0.1 surface only exposes what the bundled
  # demos actually use; richer DSL methods (before/after/not_found)
  # are layered on as the demos grow to exercise them.

  def self.get(pattern, handler);     APP.add_route("GET",     pattern, handler); end
  def self.post(pattern, handler);    APP.add_route("POST",    pattern, handler); end
  def self.put(pattern, handler);     APP.add_route("PUT",     pattern, handler); end
  def self.patch(pattern, handler);   APP.add_route("PATCH",   pattern, handler); end
  def self.delete(pattern, handler);  APP.add_route("DELETE",  pattern, handler); end


  def self.public_dir(root)
    APP.set_static_root(root)
  end

  def self.before(filter)
    APP.set_before(filter)
  end

  def self.after(filter)
    APP.set_after(filter)
  end

  def self.not_found(handler)
    APP.set_not_found(handler)
  end

  # ARGV access only emits `sp_argv` when used at top level, so the
  # translator emits the option-parsing loop itself before calling
  # `Tep.run!`. This stays a plain three-arg dispatch.
  def self.run!(port, workers, quiet)
    Server.new(APP).run(port, workers, quiet)
  end
end
