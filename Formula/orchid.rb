# Homebrew formula for orchid.
#
# PREPARE-ONLY (v1-m4 Task 11): written for a future `bilal-/homebrew-orchid`
# tap. This file is never tapped, built, or published by anything in this
# repository's own test suite or CI -- it is filled in and pushed by the
# release-day operator, per docs/install.md's "Homebrew release steps"
# section (git tag -> git archive -> shasum -> fill these two placeholders
# -> push to the tap repo). VERSION-PLACEHOLDER and SHA256-PLACEHOLDER below
# are never guessed or hand-computed here.
class Orchid < Formula
  desc "Deterministic multi-agent orchestrator for AI coding CLIs"
  homepage "https://github.com/bilal-/orchid"
  url "https://github.com/bilal-/orchid/archive/refs/tags/vVERSION-PLACEHOLDER.tar.gz"
  sha256 "SHA256-PLACEHOLDER"
  license "MIT"
  version "VERSION-PLACEHOLDER"

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
