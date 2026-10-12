# Subconscious Chromium extension

This unpacked Manifest V3 extension follows the compact mobile flyout layout: 40 px icon rail, contextual pane, compact settings, and engine connection status. It keeps the endpoint and bearer token only in `chrome.storage.local`; it has no content scripts and no broad host permission granted until the user connects.

## Load locally

1. In Chrome/Chromium, open `chrome://extensions`.
2. Enable **Developer mode**.
3. Select **Load unpacked** and choose this folder.
4. Open the Subconscious toolbar action, enter the engine URL and joining token, and select **Connect**.

The popup supports authenticated health checks, workspace list/create, thread list/create, message transcript loading, WebSocket chat, and root workspace-folder browsing. It deliberately omits content scripts; models, tools, RAG administration, and full file editing remain available in the desktop/web/Android client.

## Automated verification

Run the extension syntax/manifest validation from this directory:

```powershell
node --check popup.js
python -m json.tool manifest.json
```

The connected engine must permit `chrome-extension://` origins; the engine's CORS policy is restricted to Chromium extension IDs and loopback web development origins. Load the unpacked extension as above before Selenium extension-flow automation.
