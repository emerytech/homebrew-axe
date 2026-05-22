cask "axe" do
  version "1.7.0"
  sha256 "364e907bf86d67742562bd4d3c29aa81678380804846cfb8e9913e20c2d3de38"

  url "https://github.com/emerytech/homebrew-axe/releases/download/v#{version}/Axe.zip"
  name "Axe"
  desc "Spotlight-style overlay to quickly kill running apps"
  homepage "https://github.com/emerytech/homebrew-axe"

  depends_on :macos

  app "Axe.app"

  caveats <<~EOS
    Press ⌘A from anywhere to pop the overlay.
    While the overlay is open, ⌘A selects all apps in the list.
    No Accessibility permission required.
  EOS
end
