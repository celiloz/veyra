cask "veyra" do
  version "0.1.1"
  sha256 "25ece07e2815350dd7598e077301e56c6ab326bebecbe9d6072b384e8bffc045"

  url "https://github.com/celiloz/veyra/releases/download/v#{version}/Veyra.zip"
  name "Veyra"
  desc "Immersive macOS music dashboard with maps, weather, and focus timer"
  homepage "https://github.com/celiloz/veyra"

  depends_on macos: ">= :sonoma"

  app "Veyra.app"
end
