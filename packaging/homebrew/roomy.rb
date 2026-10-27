# Homebrew formula for the roomy CLI. Lives in the tap repo (tdermendjiev/homebrew-roomy) as Formula/roomy.rb.
# Update `url`, `sha256` and `version` per release; packaging/scripts/release.sh prints the values.
class Roomy < Formula
  desc "Find and remove regenerable developer and AI-agent artifacts safely"
  homepage "https://getroomy.dev"
  url "https://github.com/tdermendjiev/Roomy/archive/refs/tags/v1.3.0.tar.gz"
  sha256 "REPLACE_WITH_SOURCE_TARBALL_SHA256"
  license :cannot_represent
  head "https://github.com/tdermendjiev/Roomy.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on macos: :ventura

  def install
    cd "RoomyCore" do
      system "swift", "build", "--disable-sandbox", "-c", "release", "--product", "roomy"
      bin.install ".build/release/roomy"
    end
    generate_completions_from_executable(bin/"roomy", "--generate-completion-script")
    doc.install "docs/cli.md", "docs/fleet.md", "docs/agents.md"
  end

  def caveats
    <<~EOS
      roomy never deletes without a plan:
        roomy scan --plan plan.json && roomy clean --plan plan.json
      The Mac app with the review UI is at https://getroomy.dev
    EOS
  end

  test do
    assert_match "roomy", shell_output("#{bin}/roomy version")
    assert_match "projectRules", shell_output("#{bin}/roomy rules --json")
  end
end
