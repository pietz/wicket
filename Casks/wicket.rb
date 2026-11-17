cask "wicket" do
  version "0.3.7"
  sha256 "8a308a406c2d7a55f0fd0d8d179cd6a2973630a69d3ccbcde21ba1fbe91c1184"

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
