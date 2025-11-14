cask "hex" do
  version "0.2.11"
  sha256 :no_check  # Will be filled after first release

  url "https://github.com/kitlangton/hex/releases/download/v#{version}/Hex-v#{version}.zip"
  name "Hex"
  desc "On-device voice-to-text for macOS"
  homepage "https://github.com/kitlangton/hex"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  app "Hex.app"

  zap trash: [
    "~/Library/Application Support/com.kitlangton.Hex",
    "~/Library/Caches/com.kitlangton.Hex",
    "~/Library/Containers/com.kitlangton.Hex",
    "~/Library/Preferences/com.kitlangton.Hex.plist",
  ]
end
