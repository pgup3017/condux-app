---
title: Condux Guide
---

# Condux Guide

Condux is a Mac workspace for several AIs (Codex, Claude, GPT), with no Terminal skills needed. Ask questions, attach photos and PDFs, let an AI work in a project folder, and have one AI review another's work.

Three promises:

- **Your accounts and keys stay yours.** The app doesn't store sign-in tokens. API keys stay in this Mac's Keychain.
- **Costs are visible.** Each API conversation has a budget (default $1) and stops when it runs out. The app never switches you to a paid API on its own.
- **It asks first.** Edits and commands need your approval, and file changes can be reverted.

## Two versions

| | App Store (Condux Store) | Direct install (Condux) |
| --- | --- | --- |
| AI connections | Claude API, OpenAI API (your keys) | Those, plus Codex and Claude subscriptions |
| Work in a project folder | No | Yes |
| MCP tools such as Figma and Mobbin | No | Yes |
| Local AI (experimental) | No | Yes, on Apple Silicon |

## Get started

1. Press the connection status at the bottom left to open **Connections**.
2. Connect at least one AI:
   - **API key:** create a key at platform.claude.com or platform.openai.com, then press **Add Key**. Setting a low spending limit on that site is a good idea.
   - **Codex:** press **Sign In with Browser**.
   - **Claude subscription:** press **Copy Sign-in Command**, paste it into Terminal, sign in, then press **Check Again**.
3. Not sure what to pick? Press **Apply Recommended Settings**. Your keys, sign-ins, and folders aren't changed.

To change the language, open **Connections ▸ General ▸ Language**. By default, the app follows your Mac's language.

To switch between light and dark, press the sun or moon button at the top right. **Connections ▸ General ▸ Appearance** can also follow your Mac's setting.

## Web search

In API conversations, the AI can search the web and read links you give it, then lists its sources under the answer. Each search adds about $0.01 plus the cost of the result tokens to the conversation's budget. Turn it off in **Connections ▸ General ▸ Web search**. The App Store version can't control other apps such as Chrome. In the direct-install version, add the Chrome tool under **Connections ▸ Tools (MCP)**.

## GitHub and other apps (direct install)

**GitHub:** Open **Connections ▸ GitHub**. If you aren't signed in, press **Copy Sign-in Command** and run it in Terminal. Then choose a project folder in a new conversation and ask, for example, "commit this change and open a pull request." Each command needs your approval. The app never reads your GitHub token.

**Other apps:** Press **Connections ▸ Control other apps ▸ Start Control Conversation**, then ask, for example, "open example.com in Safari." This needs a Claude subscription sign-in. macOS asks for permission the first time another app is controlled.

**Chrome:** Under **Connections ▸ Tools (MCP) ▸ Add**, choose **chrome**. The AI can then open, read, and click pages in a separate Chrome window. Node is required.

## Your first conversation

Press **New Conversation** (⌘N), type in the box in the middle, and press Enter. Press Shift+Enter for a new line. Choose which AI to use on the right side of the box. The conversation is created when you send your first message.

## Files

- **Attach:** press **+**, drag files into the window, or paste a copied image with ⌘V. PNG, JPEG, PDF, and ZIP are supported.
- **Receive:** files from the AI appear in the conversation. You can open, show in Finder, or save them.

## Work in a project folder (direct install)

1. On the new conversation screen, press the folder chip and choose a project folder.
2. Ask for something, such as "find and fix the build errors".
3. When the AI wants to change a file or run a command, an approval card appears. Red lines are removed and green lines are added. Press **Allow** or **Deny**. If you don't recognize a command, it's fine to deny it.
4. Press the folder chip in the message box to run builds, send errors to the AI, and revert changed files.

## Automatic Relay

One AI builds, another reviews and sends back fixes, automatically. Write a request, then press **Relay ▸ Start Relay with This Request**. It stops when the reviewer approves or it reaches the round limit (default 3). You'll need an API key for the reviewer, and its cost counts toward the conversation's budget.

## MCP tools (direct install)

In **Connections ▸ Tools (MCP)**, press **Add** and choose Figma, Mobbin, or Xcode. Remote servers need one sign-in: use **Copy Sign-in Command** from the ⋯ menu and run it in Terminal.

## Local AI (experimental, direct install)

Chat on this Mac without an API key. Download the model (about 1 GB) under **Connections ▸ Local AI**. It's a small test model, so answers may be inaccurate, and it's text only.

## Usage and context

The small button above the message box shows how full the conversation's context is. Press it to see tokens used, the estimated API cost, and how much of your subscription limit you've used. Subscriptions never show dollar costs.

## Keyboard shortcuts

| Keys | Action |
| --- | --- |
| ⌘N | New conversation |
| Enter or ⌘Return | Send |
| Shift+Enter | New line |
| ⌘. | Stop |
| ⌘⇧A | Attach a file |
| ⌘V, Ctrl+V, or ⌘⇧V | Attach a copied image or file |
| ⌘⇧E | Export as Markdown |
| ⌘1 to ⌘9 | Go to a conversation |
| ⌘⇧, | Connections |
| ⌘? | Quick guide |

## Privacy

Conversations, attachment copies, received files, and backups stay on this Mac. Messages go only to the AI service you choose. See the [privacy policy](privacy.html).
