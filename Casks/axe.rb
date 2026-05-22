cask "axe" do
  version "1.4.2"
  sha256 "b63fff7f66f5076c403064ce4873a979182c27911ca00a1c2049db71cd7b1d4a"

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
