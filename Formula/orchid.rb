# Homebrew formula for orchid.
#
# Prepared for a future `bilal-/homebrew-orchid` tap. The pinned URL and
# checksum describe the deterministic archive produced by scripts/release.sh;
# neither this formula nor that script publishes anything.
class Orchid < Formula
  desc "Deterministic multi-agent orchestrator for AI coding CLIs"
  homepage "https://github.com/bilal-/orchid"
  url "https://github.com/bilal-/orchid/releases/download/v1.0.0-beta.1/orchid-1.0.0-beta.1.tar.gz"
  sha256 "7ffdefea8d04b9396cc6903e556ed2a9f39a418954a9d0ed094361b01824a0b9"
  license "MIT"
  version "1.0.0-beta.1"

  depends_on "git"
  depends_on "jq"

  def install
    # Mirror the repo's own layout under `libexec`, then symlink bin/orchid
    # out into Homebrew's `bin`. bin/orchid resolves ORCHID_ROOT by
    # readlink-following ITSELF to a real file, then taking that real
    # file's grandparent directory (self -> .../libexec/bin/orchid ->
    # ORCHID_ROOT=.../libexec) -- so as long as libexec/, lib/, runners/,
    # plugins/, templates/, roles/, and PROTOCOL.md all end up as siblings
    # of the bin/ directory bin/orchid's real file lives in, ORCHID_ROOT
    # resolves to exactly this formula's own libexec prefix. No wrapper
    # script, no ORCHID_ROOT env var, no rewriting bin/orchid needed --
    # the same resolution the repo's own install.sh symlink already relies
    # on (tests/test_install.sh's "resolves through the installed symlink"
    # check), just one prefix layer deeper.
    (libexec/"bin").install "bin/orchid"
    (libexec/"libexec").install Dir["libexec/*"]
    (libexec/"lib").install Dir["lib/*"]
    (libexec/"runners").install Dir["runners/*"]
    (libexec/"plugins").install Dir["plugins/*"]
    (libexec/"templates").install Dir["templates/*"]
    (libexec/"roles").install Dir["roles/*"] if File.directory?("roles")
    libexec.install "PROTOCOL.md"

    bin.install_symlink libexec/"bin/orchid" => "orchid"
  end

  def caveats
    <<~EOS
      orchid's bash+git+jq kernel is installed at:
        #{opt_libexec}

      The per-user pieces install.sh also sets up (Claude Code skill
      symlinks under ~/.claude/skills, a seeded ~/.orchid/config) are NOT
      created by this formula -- see docs/install.md for the equivalent
      manual steps if you drive orchid from inside a Claude Code session.

      From any repo you want to orchestrate:
        orchid doctor
        orchid init
    EOS
  end

  test do
    assert_match "usage: orchid", shell_output("#{bin}/orchid help")
  end
end
