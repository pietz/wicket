cask "wicket" do
  version "0.9.7"
  sha256 "fba92bf44f800e16cd23f53c0dd7d929c5243f38291c16853fa8efeb9aea1f9a"

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
