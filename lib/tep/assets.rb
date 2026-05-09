# Tep::Assets -- in-binary static asset store.
#
# Spinel produces a single static binary, so the natural way to
# ship CSS / images / JS that an app needs is to bake them INTO
# that binary rather than rely on a sibling `public/` directory.
# The build-time translator (bin/tep) auto-discovers everything
# under `<app_dir>/assets/` and emits `_add` calls that register
# each file's bytes + content-type before any handler runs.
#
# The actual storage lives on the Tep::App singleton (`APP`):
# two str_hashes keyed by path, one for body bytes and one for
# mime. Routing via the app instance keeps spinel's class-var /
# constant inference simple -- both are well-tracked instance
# variables on a class with an explicit initialiser.
#
# Conventions
# -----------
#   * The asset is served at `/<relative path>` from the project's
#     `assets/` dir. So `assets/logo.svg` -> `GET /logo.svg`.
#   * MIME type inferred from extension at build time.
#   * Binary assets pass through as Ruby string literals; spinel
#     carries the bytes through to the C compile as const char *.
#     NUL bytes truncate (spinel's :str doesn't track length), so
#     binary assets containing 0x00 should be served via
#     `Tep.public_dir` instead.
module Tep
  class Assets
    def self._add(path, body, mime)
      Tep::APP.add_asset(path, body, mime)
    end

    def self.has?(path)
      Tep::APP.asset_bodies.has_key?(path)
    end

    # Serve `path` if it's known. Sets Content-Type / body and
    # returns true; returns false if the path isn't bundled.
    def self.serve(path, res)
      if !Tep::APP.asset_bodies.has_key?(path)
        return false
      end
      res.headers["Content-Type"] = Tep::APP.asset_mimes[path]
      res.headers["Cache-Control"] = "public, max-age=3600"
      res.set_body_if_empty(Tep::APP.asset_bodies[path])
      true
    end
  end
end
