#!/usr/bin/env python3
"""Generate a pinned cask from a release ZIP. Does not upload anything."""
import hashlib, re, sys
from pathlib import Path
version, archive = sys.argv[1:]
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    raise SystemExit("Expected a semantic version")
checksum = hashlib.sha256(Path(archive).read_bytes()).hexdigest()
cask = f'''cask "veyra" do
  version "{version}"
  sha256 "{checksum}"

  url "https://github.com/celiloz/veyra/releases/download/v#{{version}}/Veyra-#{{version}}-universal.zip"
  name "Veyra"
  desc "Immersive macOS music dashboard with maps, weather, and focus timer"
  homepage "https://github.com/celiloz/veyra"

  depends_on macos: ">= :sonoma"

  app "Veyra.app"
end
'''
(Path(__file__).resolve().parents[1] / "Casks/veyra.rb").write_text(cask)
