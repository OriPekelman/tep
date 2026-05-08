# Tep "hello" demo -- exercises the full v0.1 surface.
require_relative "../lib/tep"

class Root < Tep::Handler
  def handle(req, res)
    "<!doctype html><html><head><title>tep " + Tep::VERSION + "</title>" +
    "<link rel=\"stylesheet\" href=\"/style.css\">" +
    "</head><body>" +
    "<h1>tep " + Tep::VERSION + "</h1>" +
    "<p>Sinatra-flavoured framework, AOT-compiled by Spinel.</p>" +
    "<ul>" +
    "<li><a href=\"/hi/world\">/hi/:name</a> -- path params</li>" +
    "<li><a href=\"/search?q=ruby&page=2\">/search?q=...&page=...</a> -- query string</li>" +
    "<li><a href=\"/square/12\">/square/:n</a> -- typed path param</li>" +
    "<li><a href=\"/about\">/about</a> -- custom Content-Type</li>" +
    "<li><a href=\"/old\">/old</a> -- 302 redirect</li>" +
    "<li><a href=\"/secret\">/secret</a> -- 401 halt</li>" +
    "<li><a href=\"/hello.txt\">/hello.txt</a> -- static file from public/</li>" +
    "<li><a href=\"/style.css\">/style.css</a> -- static CSS</li>" +
    "<li><a href=\"/missing\">/missing</a> -- custom 404</li>" +
    "<li>POST /echo (form-urlencoded body)</li>" +
    "</ul></body></html>"
  end
end

class Hi < Tep::Handler
  def handle(req, res)
    "<p>hi, " + req.params["name"] + "!</p>\n"
  end
end

class Search < Tep::Handler
  def handle(req, res)
    "<p>q=" + req.params["q"] + " page=" + req.params["page"] + "</p>\n"
  end
end

class Square < Tep::Handler
  def handle(req, res)
    n = req.params["n"].to_i
    "<p>" + n.to_s + "<sup>2</sup> = " + (n * n).to_s + "</p>\n"
  end
end

class About < Tep::Handler
  def handle(req, res)
    res.headers["Content-Type"] = "text/plain; charset=utf-8"
    "tep " + Tep::VERSION + " -- spinel-compiled Sinatra-flavoured framework\n"
  end
end

class Old < Tep::Handler
  def handle(req, res)
    res.set_status(302)
    res.headers["Location"] = "/"
    ""
  end
end

class Secret < Tep::Handler
  def handle(req, res)
    res.set_status(401)
    res.headers["WWW-Authenticate"] = "Basic realm=\"tep\""
    "<h1>401</h1><p>nothing here for you.</p>\n"
  end
end

class Echo < Tep::Handler
  def handle(req, res)
    res.headers["Content-Type"] = "text/plain; charset=utf-8"
    "verb=" + req.verb + "\n" +
    "path=" + req.path + "\n" +
    "name=" + req.params["name"] + "\n" +
    "body=" + req.raw_body + "\n"
  end
end

class CustomNotFound < Tep::Handler
  def handle(req, res)
    res.headers["Content-Type"] = "text/html; charset=utf-8"
    "<h1>nope -- " + req.path + "</h1>" +
    "<p>this is a custom 404 page from Tep.not_found</p>\n"
  end
end

class LoggerFilter < Tep::Filter
  def before(req, res)
    puts "[" + req.verb + "] " + req.path
    0
  end
end

class TimerFilter < Tep::Filter
  def after(req, res)
    res.headers["X-Tep-Powered-By"] = "spinel-aot"
    0
  end
end

# ---- registrations ----

# Spinel doesn't have `__dir__` at compile time, so the path
# substituted here has to be absolute *or* relative to the binary's
# CWD at runtime. Adjust to suit your deployment.
Tep.public_dir "./public"
Tep.before     LoggerFilter.new
Tep.after      TimerFilter.new
Tep.not_found  CustomNotFound.new

Tep.get  "/",            Root.new
Tep.get  "/hi/:name",    Hi.new
Tep.get  "/search",      Search.new
Tep.get  "/square/:n",   Square.new
Tep.get  "/about",       About.new
Tep.get  "/old",         Old.new
Tep.get  "/secret",      Secret.new
Tep.post "/echo",        Echo.new

# port, workers, quiet
Tep.run!(4567, 1, false)
