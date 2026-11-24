cask "wicket" do
  version "0.7.6"
  sha256 "0c9918a4bd364579764c74fbe04fd12617b47ae408ecab5b2ff004e113823116"

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
