cask "veyra" do
  version "0.1.0"
  sha256 "b56564d45d26eb0dc2928ef935cb0bbd3e723dea5a63e87a80308a71dc5e2b11"

  url "https://github.com/celiloz/veyra/releases/download/v#{version}/Veyra-#{version}-universal.zip"
  name "Veyra"
  desc "Immersive macOS music dashboard with maps, weather, and focus timer"
  homepage "https://github.com/celiloz/veyra"

  depends_on macos: ">= :sonoma"

  app "Veyra.app"
end
