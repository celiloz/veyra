cask "veyra" do
  version "0.1.3"
  sha256 "5e05ab958697e3f998deb4ff49d0389979c7840048bd86f0d3924fe62e75186b"

  url "https://github.com/celiloz/veyra/releases/download/v#{version}/Veyra-#{version}-arm64.zip"
  name "Veyra"
  desc "Immersive macOS music dashboard with maps, weather, and focus timer"
  homepage "https://github.com/celiloz/veyra"

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Veyra.app"
end
