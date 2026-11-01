# Security

Please report vulnerabilities privately through [GitHub security advisories](https://github.com/pgup3017/condux-app/security/advisories/new), not in public issues.

## What Condux protects

- API keys are stored only in the macOS Keychain and are removed from logs and error messages.
- Condux doesn't read Claude, Codex, or GitHub sign-in tokens or credential files.
- Commands always need approval. Auto-approval covers only file edits inside the project folder and the received-files folder.

## Risks that remain

- **Prompt injection:** Web pages, files, and tool results can contain instructions aimed at the AI. Approval cards are the main defense, so read commands before allowing them.
- **Approved commands run as you.** An approved command has your full user permissions, and changes it makes can't be reverted by Condux.
- **MCP servers are third-party code.** Add only the ones you trust. The Chrome preset downloads its package with `npx` on first run.
- **Local builds aren't notarized.** Build from source you've reviewed.
