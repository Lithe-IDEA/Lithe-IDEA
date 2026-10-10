cask "lithe" do
  arch arm: "arm64", intel: "x86_64"

  version "0.6.0"
  sha256 arm:   "d7b60a36cdf8819216e7ad2ffb61422bcc53ba7a89702d1d22dd024a34f980fd",
         intel: "274e8a888fd909512a02fcbfa96d6e05040669347ad88060dd11620a43785a0b"

  url "https://github.com/Lithe-IDEA/Lithe-IDEA/releases/download/v#{version}/Lithe-#{version}-#{arch}.dmg"
  name "Lithe"
  desc "Native IDE for AI-assisted Java development"
  homepage "https://github.com/Lithe-IDEA/Lithe-IDEA"

  livecheck do
    url :homepage
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "Lithe.app"

  # This project tap intentionally clears quarantine after the verified download.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Lithe.app"]
  end

  uninstall quit: "app.lithe.desktop"

  zap trash: [
    "~/Library/Application Support/Lithe",
    "~/Library/Preferences/app.lithe.desktop.plist",
    "~/Library/Saved Application State/app.lithe.desktop.savedState",
  ]
end
