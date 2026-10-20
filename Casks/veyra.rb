cask "veyra" do
  version "0.1.2"
  sha256 "1688718453ce4b86bd394cc837154c1ab91461ff09e255da545a25754bf4f5b5"

  url "https://github.com/celiloz/veyra/releases/download/v#{version}/Veyra.zip"
  name "Veyra"
  desc "Immersive macOS music dashboard with maps, weather, and focus timer"
  homepage "https://github.com/celiloz/veyra"

  depends_on macos: ">= :sonoma"

  app "Veyra.app"
end
