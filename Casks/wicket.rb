cask "wicket" do
  version "0.1.0"
  sha256 "fec5950b9d8211bc454da706dc25b7ddc2870ab2d9012efa2e3fbbdbe8021f60"

  url "https://github.com/pietz/wicket/releases/download/v#{version}/Wicket-#{version}.dmg"
  name "Wicket"
  desc "Small, fast, native launcher whose extensions are written by agents"
  homepage "https://github.com/pietz/wicket"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :tahoe"

  app "Wicket.app"

  zap trash: [
    "~/.config/wicket",
    "~/Library/Application Support/Wicket",
    "~/Library/Caches/app.wicket.Wicket",
    "~/Library/HTTPStorages/app.wicket.Wicket",
    "~/Library/Preferences/app.wicket.Wicket.plist",
  ]
end
