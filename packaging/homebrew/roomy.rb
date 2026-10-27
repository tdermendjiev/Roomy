# Homebrew formula for the roomy CLI. Lives in the tap repo (tdermendjiev/homebrew-roomy) as Formula/roomy.rb.
# Installs the signed and notarized universal binary from the GitHub release, so no Xcode is needed.
# The release workflow rewrites `url`, `sha256` and `version` on every tagged release.
class Roomy < Formula
  desc "Free up the disk space developer tools and AI agents leave behind"
  homepage "https://getroomy.dev"
  url "https://github.com/tdermendjiev/Roomy/releases/download/v1.3.0/roomy-1.3.0-macos-universal.tar.gz"
  sha256 "d3990ae418c6c2d1e843444e1ff37a5fce5ee301b7f0125b790b118153ffd0f2"
  version "1.3.0"
  license "Apache-2.0"

  depends_on macos: :ventura

  def install
    bin.install "roomy"
    generate_completions_from_executable(bin/"roomy", "--generate-completion-script")
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
