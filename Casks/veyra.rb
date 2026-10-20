cask "veyra" do
  version "0.1.0"
  sha256 "c38678b134001a2baec92636371d6eaac61a92b500e7415c16a899d956f4eae6"

  url "https://github.com/celiloz/veyra/releases/download/v#{version}/Veyra-#{version}-universal.zip"
  name "Veyra"
  desc "Immersive macOS music dashboard with maps, weather, and focus timer"
  homepage "https://github.com/celiloz/veyra"

  depends_on macos: ">= :sonoma"

  app "Veyra.app"
end
