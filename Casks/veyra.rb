cask "veyra" do
  version "0.1.4"
  sha256 "2d3f367d3f89b5c4868f00d5d6a966c8f34e1e540984aedc0636ecf4956a9e71"

  url "https://github.com/celiloz/veyra/releases/download/v#{version}/Veyra-#{version}-arm64.zip"
  name "Veyra"
  desc "Immersive macOS music dashboard with maps, weather, and focus timer"
  homepage "https://github.com/celiloz/veyra"

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Veyra.app"
end
