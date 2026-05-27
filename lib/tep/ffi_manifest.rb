# Tep FFI manifest -- the single declarative source of truth for the
# `@TEP_*@` placeholders tep's FFI shims carry, so build-time tools
# (tep's own bin/tep, and consumers' post-vendor readers like toy's
# prep/post_vendor_tep.rb) stop each hardcoding the same substitution
# list. Adding a new FFI shim becomes one manifest entry that every
# consumer picks up unchanged. See OriPekelman/tep#97.
#
# BUILD-TIME, CRuby-ONLY. This file is deliberately NOT required by
# lib/tep.rb, so Spinel never compiles it -- two reasons it can't be
# in the compile path:
#   1. ENTRIES is an array of mixed-value hashes; Spinel types that
#      poly and `entry[:x]` fails to resolve.
#   2. The point of a manifest would be to drive `require_relative`,
#      but Spinel's inliner only follows *literal* require_relative
#      (no runtime require) -- a computed `require_relative entry[:file]`
#      is a no-op. So lib/tep.rb keeps static requires; this manifest
#      informs the *build tools*, which run under CRuby, instead.
#
# `optional:` formalises the old `-DNO_PG` hack: a consumer that
# doesn't use a battery sets TEP_DISABLE=pg (comma-separated), and the
# reader skips that entry's substitution -- and the build tool skips
# inlining its file (the require-gate lives in the inliner, since
# lib/tep.rb can't conditionally require under Spinel).
#
# Resolution `kind` per placeholder:
#   :obj              -> absolute path to the built .o
#   :obj_plus_libs    -> "<.o> <linker libs>"        (e.g. .o + -lsqlite3)
#   :cflags_plus_libs -> "<compile cflags> <libs>"   (e.g. libpq cflags+libs)
module Tep
  module FFIManifest
    ENTRIES = [
      {
        module:   "sphttp",
        file:     "tep/net.rb",
        obj:      "tep/sphttp.o",
        optional: false,
        # Crypto (sp_crypto_*) lives in spinel's libspinel_rt.a since
        # matz/spinel#514 -- auto-linked, no placeholder needed here.
        placeholders: {
          "@TEP_SPHTTP_O@" => { kind: :obj, obj_env: "TEP_SPHTTP_O" },
        },
      },
      {
        module:   "sqlite",
        file:     "tep/sqlite.rb",
        obj:      "tep/tep_sqlite.o",
        optional: true,
        pkg_config:          "sqlite3",
        pkg_config_fallback: "-lsqlite3",
        placeholders: {
          # tep's own builds export TEP_SQLITE_O = the bare .o (the
          # link env resolves sqlite3 itself); a pkg-config-driven
          # consumer (toy) wants .o + libs. Both are `:obj_plus_libs`
          # with the libs resolved per-consumer (env / pkg-config).
          "@TEP_SQLITE_O@" => { kind: :obj_plus_libs, obj_env: "TEP_SQLITE_O", libs_env: "TEP_SQLITE_LIBS" },
        },
      },
      {
        module:   "pg",
        file:     "tep/pg.rb",
        obj:      "tep/tep_pg.o",
        optional: true,
        pkg_config:          "libpq",
        pkg_config_fallback: nil,   # bail loud: no safe default for libpq
        placeholders: {
          "@TEP_PG_O@"      => { kind: :obj, obj_env: "TEP_PG_O" },
          "@TEP_PG_CFLAGS@" => { kind: :cflags_plus_libs, cflags_env: "TEP_PG_CFLAGS", libs_env: "TEP_PG_LIBS", libs_default: "-lpq" },
        },
      },
    ].freeze

    # Modules a consumer opted out of via TEP_DISABLE=mod1,mod2.
    def self.disabled
      (ENV["TEP_DISABLE"] || "").split(",").map(&:strip).reject(&:empty?)
    end

    def self.disabled?(entry)
      entry[:optional] && disabled.include?(entry[:module])
    end

    # The basename (no .rb) of an entry's shim file -- what bin/tep's
    # inliner matches against to skip a disabled module.
    def self.require_stem(entry)
      entry[:file].sub(/\.rb\z/, "")
    end

    # Build the {placeholder => resolved string} substitution dict for
    # bin/tep, faithful to its historical env-first behavior:
    #   * .o paths come from the per-placeholder obj_env (the Makefile
    #     exports these), defaulting to <lib_dir>/<entry[:obj]>.
    #   * pg cflags come from TEP_PG_CFLAGS + TEP_PG_LIBS (Makefile-set
    #     via pkg-config), defaulting to "" + "-lpq".
    #   * sqlite libs come from TEP_SQLITE_LIBS if set, else "" (tep's
    #     own env links sqlite3 without an explicit lib).
    #
    # Every placeholder is always resolved -- a *skipped* placeholder
    # would survive into the source and Spinel would reject it. True
    # battery-exclusion (TEP_DISABLE not inlining tep/pg.rb) is a
    # separate, harder concern: lib/tep.rb's type-seeds reference
    # Tep::PG / Tep::SQLite, so excluding the file breaks the seed
    # block. The `optional` / `disabled?` helpers below are metadata
    # for consumers that want to attempt it; bin/tep itself resolves
    # all placeholders, unchanged from before this manifest landed.
    def self.bin_tep_subs(lib_dir)
      subs = {}
      ENTRIES.each do |entry|
        default_obj = File.join(lib_dir, entry[:obj])
        entry[:placeholders].each do |placeholder, spec|
          subs[placeholder] = resolve_bin_tep(spec, default_obj)
        end
      end
      subs
    end

    def self.resolve_bin_tep(spec, default_obj)
      case spec[:kind]
      when :obj
        ENV.fetch(spec[:obj_env], default_obj)
      when :obj_plus_libs
        obj  = ENV.fetch(spec[:obj_env], default_obj)
        libs = spec[:libs_env] ? ENV.fetch(spec[:libs_env], "") : ""
        "#{obj} #{libs}".strip
      when :cflags_plus_libs
        cflags = spec[:cflags_env] ? ENV.fetch(spec[:cflags_env], "") : ""
        libs   = spec[:libs_env]   ? ENV.fetch(spec[:libs_env], spec[:libs_default] || "") : ""
        "#{cflags} #{libs}".strip
      else
        ""
      end
    end
  end
end
