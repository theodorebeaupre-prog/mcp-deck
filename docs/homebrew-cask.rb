# Homebrew cask template for MCP Deck.
# Published at github.com/theodorebeaupre-prog/homebrew-tap (Casks/mcp-deck.rb).
# Keep this copy in sync: update `version` and `sha256` on each release:
#   shasum -a 256 MCP-Deck-vX.Y.Z.zip
cask "mcp-deck" do
  version "0.1.0"
  sha256 "9613771966e5ec3a9f7019f0295a78c7ae5b1e55deb59105db042c27c3486908"

  url "https://github.com/theodorebeaupre-prog/mcp-deck/releases/download/v#{version}/MCP-Deck-v#{version}.zip"
  name "MCP Deck"
  desc "Menu bar dashboard for MCP servers across Claude Desktop, Claude Code, and Cursor"
  homepage "https://github.com/theodorebeaupre-prog/mcp-deck"

  depends_on macos: :sonoma

  app "MCPDeck.app"

  zap trash: [
    "~/Library/Preferences/com.theodorebeaupre.MCPDeck.plist",
  ]
end
