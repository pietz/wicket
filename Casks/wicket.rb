cask "wicket" do
  version "0.10.1"
  sha256 "a32d32e8b0c12603b3bdedd4980dba19b8e8e0cd244d326ea861be18a5416aca"

  url "https://github.com/pietz/wicket/releases/download/v#{version}/Wicket-#{version}.dmg"
  name "Wicket"
  desc "Small, fast, native launcher whose extensions are written by agents"
  homepage "https://github.com/pietz/wicket"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :golden_gate"

  app "Wicket.app"

  zap trash: [
    "~/.config/wicket",
    "~/Library/Application Support/Wicket",
    "~/Library/Caches/app.wicket.Wicket",
    "~/Library/HTTPStorages/app.wicket.Wicket",
    "~/Library/Preferences/app.wicket.Wicket.plist",
  ]
end
