# Homebrew formula for orchid.
#
# Prepared for the `bilal-/homebrew-tap` repository. The pinned URL and
# checksum describe the deterministic archive produced by scripts/release.sh;
# neither this formula nor that script publishes anything.
class Orchid < Formula
  desc "Deterministic multi-agent orchestrator for AI coding CLIs"
  homepage "https://orchid.bilal.sh"
  url "https://github.com/bilal-/orchid/releases/download/v1.0.0-beta.1/orchid-1.0.0-beta.1.tar.gz"
  sha256 "913b8395b5f52f64af1b56d393c198f93b7260f3c3ac2941a4ab73dd3960b65b"
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
    libexec.install "PROTOCOL.md", "orchid.config.example", "install.sh"
    libexec.install "skills", "skills-external", "docs", "release"
    (libexec/"scripts").install "scripts/beta-qualify.sh"
    prefix.install "README.md", "LICENSE"

    bin.install_symlink libexec/"bin/orchid" => "orchid"
  end

  def caveats
    <<~EOS
      orchid's bash+git+jq kernel is installed at:
        #{opt_libexec}

      Set up skills for your installed agent frontends and seed user config:
        bash "#{opt_libexec}/install.sh"

      The stable Homebrew opt path keeps those skill links valid on upgrade.
      Installation details: #{opt_libexec}/docs/install.md

      From any repo you want to orchestrate:
        orchid doctor
        orchid init
    EOS
  end

  test do
    assert_match "usage: orchid", shell_output("#{bin}/orchid help")
    assert_match version.to_s, shell_output("#{bin}/orchid version")
    assert_equal version.to_s, shell_output("#{bin}/orchid --version").strip
    assert_match "integration_branch", shell_output("#{bin}/orchid config list")
    %w[README.md LICENSE].each { |path| assert_path_exists prefix/path }
    %w[install.sh orchid.config.example PROTOCOL.md
       skills/orchid/SKILL.md skills/orchid-plan/SKILL.md skills/orchid-resume/SKILL.md
       skills-external/openclaw-orchid/SKILL.md docs/install.md scripts/beta-qualify.sh].each do |path|
      assert_path_exists libexec/path
    end
    assert_equal (libexec/"bin/orchid").realpath, (bin/"orchid").realpath
  end
end
