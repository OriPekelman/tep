# tep blog -- a flagship demo exercising every batteries-included
# tep feature in a coherent ~200 lines:
#
#   - Tep::SQLite        posts + users tables
#   - Tep::Password      PBKDF2 password hashing
#   - Tep::Jwt           JSON API token issue / verify
#   - Sessions           web-side login (signed cookie)
#   - Tep::Json          JSON encode + flat-key decode
#   - Tep::Logger        request log + auth events
#   - Tep::Security      CORS + secure-headers
#   - ERB + @ivar locals public-facing views
#
# Build + run:
#
#     bin/tep build examples/blog/app.rb -o /tmp/blog
#     TEP_SESSION_SECRET=$(openssl rand -hex 32) /tmp/blog -p 4567
#
# First-time setup creates /tmp/tep_blog.db and seeds an admin
# user (alice / hunter2). See SINATRA_COMPAT.md for the feature
# matrix this app exercises end-to-end.

require 'sinatra'

# -------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------

DB_PATH       = ENV.fetch("TEP_BLOG_DB",     "/tmp/tep_blog.db")
JWT_SECRET    = ENV.fetch("TEP_JWT_SECRET",  "dev-jwt-secret-change-me")
SESSION_SEED  = ENV.fetch("TEP_SESSION_SECRET", "dev-session-secret-change-me")
SEED_USER     = "alice"
SEED_PASSWORD = "hunter2"

# Sessions need a stable HMAC secret; in production set
# TEP_SESSION_SECRET to 32 random bytes. We accept the dev default
# at build time for convenience.
Tep.session_secret = SESSION_SEED

LOGGER = Tep::Logger.new
LOGGER.set_level("info")

CORS = Tep::Security::Cors.new
CORS.set_origin("*")
CORS.set_allowed_verbs("GET,POST,OPTIONS")
CORS.set_allowed_headers("Content-Type,Authorization")
Tep.before CORS

HEADERS = Tep::Security::Headers.new
Tep.after HEADERS

set :views, File.expand_path("views", __dir__)

# -------------------------------------------------------------------
# Schema + seed
# -------------------------------------------------------------------

on_start do
  db = Tep::SQLite.new
  if db.open(DB_PATH)
    db.exec("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT UNIQUE, pwd_hash TEXT)")
    db.exec("CREATE TABLE IF NOT EXISTS posts (id INTEGER PRIMARY KEY, title TEXT, body TEXT, author TEXT, created_at INTEGER)")
    # Seed the admin user once if the table is empty.
    n = db.first_int("SELECT count(*) FROM users", "")
    if n == 0
      hash = Tep::Password.create(SEED_PASSWORD)
      db.prepare("INSERT INTO users (name, pwd_hash) VALUES (?, ?)")
      db.bind_str(1, SEED_USER)
      db.bind_str(2, hash)
      db.step
      db.finalize
      LOGGER.info("seeded admin user: " + SEED_USER)
    end
    # Seed an introductory post on the first boot so the homepage
    # isn't empty for a new install. Idempotent: only inserts when
    # the posts table is still empty, so wiping `users` on its own
    # won't double-seed and re-seeding never duplicates.
    pn = db.first_int("SELECT count(*) FROM posts", "")
    if pn == 0
      seed_body =
        "<p>This blog is the flagship demo for " +
        "<a href=\"https://github.com/OriPekelman/tep\">tep</a>, " +
        "a Sinatra-flavoured framework that compiles to a single " +
        "static binary via <a href=\"https://github.com/matz/spinel\">Spinel</a> " +
        "(an AOT Ruby compiler).</p>" +
        "<p>The whole site -- routes, ERB views, sessions, JSON " +
        "API, JWT-authed writes, and the SQLite store you're " +
        "reading from -- ships in <code>examples/blog/app.rb</code> " +
        "(~250 lines) plus four ERB templates. No Rack, no Bundler, " +
        "no MRI runtime: <code>tep build</code> turns it into a " +
        "C-compiled binary that links libsqlite3 and serves HTTP " +
        "directly via a small <code>sphttp.c</code> shim.</p>" +
        "<p>Browse around: log in as <code>alice / hunter2</code> " +
        "to write a post, or hit <code>GET /api/posts</code> for " +
        "the JSON view. <code>POST /api/token</code> issues a JWT " +
        "you can use against <code>POST /api/posts</code>.</p>"
      db.prepare("INSERT INTO posts (title, body, author, created_at) VALUES (?, ?, ?, ?)")
      db.bind_str(1, "Welcome to tep + spinel")
      db.bind_str(2, seed_body)
      db.bind_str(3, SEED_USER)
      db.bind_int(4, Time.now.to_i)
      db.step
      db.finalize
      LOGGER.info("seeded intro post")
    end
    db.close
  end
end

# -------------------------------------------------------------------
# Per-request log
# -------------------------------------------------------------------

before do
  LOGGER.info(req.verb + " " + req.path)
end

# -------------------------------------------------------------------
# Helpers (inlined per route -- spinel's translator doesn't do
# `helpers do ... end` blocks, by design)
# -------------------------------------------------------------------
#
#   db_open()                 -> Tep::SQLite already open on DB_PATH
#   current_user(req)         -> session-cookie name or "" when absent
#   require_login(req, res)   -> set 401 + halt if not logged in
#   verify_jwt_user(req)      -> the `sub` claim from the bearer token, or "" on failure
#
# Callers use simple if-checks; no closures.

# -------------------------------------------------------------------
# Public web pages
# -------------------------------------------------------------------

get '/' do
  db = Tep::SQLite.new
  db.open(DB_PATH)

  posts_html = ""
  db.prepare("SELECT id, title, author, created_at FROM posts ORDER BY id DESC")
  while db.step == 1
    posts_html = posts_html +
      "<li><a href=\"/post/" + db.col_int(0).to_s + "\">" +
      Tep.h(db.col_str(1)) + "</a> <span>by " +
      Tep.h(db.col_str(2)) + "</span></li>"
  end
  db.finalize
  db.close

  @posts_html  = posts_html
  @logged_in   = req.session.has?("user") ? "1" : ""
  @user        = req.session.get("user")
  erb :index
end

get '/post/:id' do
  db = Tep::SQLite.new
  db.open(DB_PATH)
  id = params[:id]
  @title  = db.first_str("SELECT title  FROM posts WHERE id = ?", id)
  @body   = db.first_str("SELECT body   FROM posts WHERE id = ?", id)
  @author = db.first_str("SELECT author FROM posts WHERE id = ?", id)
  db.close

  if @title.length == 0
    res.set_status(404)
    return "<h1>not found</h1>"
  end
  erb :show
end

# -------------------------------------------------------------------
# Auth (web): sessions
# -------------------------------------------------------------------

get '/login' do
  @flash = ""
  erb :login
end

post '/login' do
  user = params[:user]
  pwd  = params[:password]

  db = Tep::SQLite.new
  db.open(DB_PATH)
  db.prepare("SELECT pwd_hash FROM users WHERE name = ?")
  db.bind_str(1, user)
  hash = ""
  if db.step == 1
    hash = db.col_str(0)
  end
  db.finalize
  db.close

  if hash.length > 0 && Tep::Password.verify(pwd, hash)
    req.session.set("user", user)
    LOGGER.info("login ok: " + user)
    res.headers["Location"] = "/"
    res.set_status(302)
    return ""
  end

  LOGGER.warn("login failed: " + user)
  @flash = "invalid credentials"
  res.set_status(401)
  erb :login
end

post '/logout' do
  user = req.session.get("user")
  req.session.set("user", "")
  LOGGER.info("logout: " + user)
  res.headers["Location"] = "/"
  res.set_status(302)
  ""
end

# -------------------------------------------------------------------
# Admin (session-required) -- create posts
# -------------------------------------------------------------------

get '/admin/new' do
  if !req.session.has?("user")
    res.set_status(401)
    return "<h1>401</h1><p><a href=\"/login\">log in</a></p>"
  end
  @user = req.session.get("user")
  erb :new_post
end

post '/admin/new' do
  if !req.session.has?("user")
    res.set_status(401)
    return ""
  end
  user = req.session.get("user")

  db = Tep::SQLite.new
  db.open(DB_PATH)
  db.prepare("INSERT INTO posts (title, body, author, created_at) VALUES (?, ?, ?, ?)")
  db.bind_str(1, params[:title])
  db.bind_str(2, params[:body])
  db.bind_str(3, user)
  db.bind_int(4, Time.now.to_i)
  db.step
  db.finalize
  id = db.last_rowid
  db.close

  LOGGER.info("post created id=" + id.to_s + " by " + user)
  res.headers["Location"] = "/post/" + id.to_s
  res.set_status(302)
  ""
end

# -------------------------------------------------------------------
# JSON API
# -------------------------------------------------------------------

get '/api/posts' do
  res.headers["Content-Type"] = "application/json"
  db = Tep::SQLite.new
  db.open(DB_PATH)

  out = "["
  first = true
  db.prepare("SELECT id, title, author FROM posts ORDER BY id DESC")
  while db.step == 1
    if !first
      out = out + ","
    end
    first = false
    out = out + "{" +
      Tep::Json.encode_pair_int("id", db.col_int(0)) + "," +
      Tep::Json.encode_pair_str("title",  db.col_str(1)) + "," +
      Tep::Json.encode_pair_str("author", db.col_str(2)) + "}"
  end
  db.finalize
  db.close
  out + "]"
end

get '/api/posts/:id' do
  res.headers["Content-Type"] = "application/json"
  db = Tep::SQLite.new
  db.open(DB_PATH)
  id = params[:id]
  title  = db.first_str("SELECT title  FROM posts WHERE id = ?", id)
  body   = db.first_str("SELECT body   FROM posts WHERE id = ?", id)
  author = db.first_str("SELECT author FROM posts WHERE id = ?", id)
  db.close
  if title.length == 0
    res.set_status(404)
    return "{}"
  end
  "{" +
    Tep::Json.encode_pair_str("title",  title) + "," +
    Tep::Json.encode_pair_str("body",   body)  + "," +
    Tep::Json.encode_pair_str("author", author) + "}"
end

# Issue a JWT for API access. Same credentials as web login.
post '/api/token' do
  res.headers["Content-Type"] = "application/json"
  user = Tep::Json.get_str(req.raw_body, "user")
  pwd  = Tep::Json.get_str(req.raw_body, "password")

  db = Tep::SQLite.new
  db.open(DB_PATH)
  db.prepare("SELECT pwd_hash FROM users WHERE name = ?")
  db.bind_str(1, user)
  hash = ""
  if db.step == 1
    hash = db.col_str(0)
  end
  db.finalize
  db.close

  if hash.length == 0 || !Tep::Password.verify(pwd, hash)
    res.set_status(401)
    LOGGER.warn("api token denied: " + user)
    return "{\"error\":\"invalid credentials\"}"
  end

  payload = "{" +
    Tep::Json.encode_pair_str("sub", user) + "," +
    Tep::Json.encode_pair_int("exp", Time.now.to_i + 3600) + "}"
  token = Tep::Jwt.encode_hs256(payload, JWT_SECRET)
  LOGGER.info("api token issued: " + user)
  "{\"token\":\"" + token + "\"}"
end

post '/api/posts' do
  res.headers["Content-Type"] = "application/json"
  auth = req.req_headers["authorization"]
  bearer = ""
  if auth.length > 7 && auth[0, 7] == "Bearer "
    bearer = auth[7, auth.length - 7]
  end
  payload = ""
  if bearer.length > 0
    payload = Tep::Jwt.verify_and_decode(bearer, JWT_SECRET)
  end
  if payload.length == 0
    res.set_status(401)
    return "{\"error\":\"unauthorized\"}"
  end
  user = Tep::Json.get_str(payload, "sub")

  title = Tep::Json.get_str(req.raw_body, "title")
  body  = Tep::Json.get_str(req.raw_body, "body")

  db = Tep::SQLite.new
  db.open(DB_PATH)
  db.prepare("INSERT INTO posts (title, body, author, created_at) VALUES (?, ?, ?, ?)")
  db.bind_str(1, title)
  db.bind_str(2, body)
  db.bind_str(3, user)
  db.bind_int(4, Time.now.to_i)
  db.step
  db.finalize
  id = db.last_rowid
  db.close

  LOGGER.info("api post created id=" + id.to_s + " by " + user)
  res.set_status(201)
  "{" + Tep::Json.encode_pair_int("id", id) + "}"
end
