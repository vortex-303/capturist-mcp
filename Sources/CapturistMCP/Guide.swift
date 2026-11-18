/// Single source for help, the agent guide, the Claude Code Skill, AGENTS.md blocks and MCP descriptions.
public enum Guide {
    public static let version = "0.4.2"

    public static let summary = "Capturist holds the user's screenshots, saved snippets and recent clipboard on this Mac. Use it whenever the user refers to a screenshot, a capture, something on their screen, a snippet, or something they copied."

    public static let skillDescription = "Read the user's Capturist screenshots, snippets and clipboard on this Mac. Use when the user mentions a screenshot, capture, clip, snippet, something on screen, something they copied, or an error/design/page they saw."

    public static let usage = """
    capturist \(version) — your Capturist screenshots, snippets and clipboard for agents and scripts.

    USAGE
      capturist recent [--since 2h] [--kind image|text|pdf] [--limit 20]   newest captures
      capturist search <words…> [--kind …] [--limit 20]                  name, app, window title, and text inside images
      capturist show <ref>                                                details + file path (open it to see the image)
      capturist text <ref>                                                text inside a capture (read on this Mac)
      capturist clips [--since 1h] [--limit 50]                           clipboard history (if turned on in Capturist)
      capturist index [--force]                                           update the text index (search does this itself)
      capturist guide                                                     how agents should use Capturist
      capturist setup <claude-code|opencode|codex|claude-desktop|cursor|chatgpt|shortcut> [--remove] [--notify] [--yes]
      capturist setup --list                                              what's installed
      capturist doctor                                                    check library access, index and setup
      capturist mcp                                                       MCP server (stdio) for Claude, ChatGPT, Codex …: relays to the running app (all tools), else reads the library

    OPTIONS
      --json                 machine-readable output (stable fields)
      --library store|complete|dev|<path>   which library (default: the running app, else the one used most recently; env CAPTURIST_LIBRARY)

    REFS
      latest, latest~1, latest~2 …, or the first characters of an id (e.g. 3f9a2c1b)

    EXIT CODES
      0 ok · 1 nothing found · 2 bad input · 3 library missing or not readable
    """

    public static let agentGuide = """
    # Capturist (screen context on this Mac)

    \(summary) Everything stays local; nothing is uploaded.

    ## When to use it
    - "look at my screenshot", "the error I captured", "what I copied", "the design I clipped", "my last capture"
    - The user describes something they saw on screen and it may be in their captures.

    ## Commands (add --json for structured output)
    - `capturist recent --since 2h` — newest captures (id, kind, app, name).
    - `capturist search "invoice 502"` — matches names, source app/window and the text inside images.
    - `capturist show latest --json` — details including `path`; open that file to see the image.
    - `capturist text latest` — the text inside a capture (fast to read, good for errors and code).
    - `capturist clips --since 1h` — recent clipboard text (only if the user enabled clipboard history).

    ## Refs
    `latest`, `latest~1` (the one before), or the first 8 characters of an id from a listing.

    ## Tips
    - Prefer `text` for errors, logs and code; open the `path` image when layout or visuals matter.
    - JSON fields: id, shortId, created, kind (image|text|pdf), name, app, title, url, path, width, height, size, shareUrl, text.
    - Exit code 1 means nothing matched; say so rather than guessing.
    - Read-only: Capturist itself is where the user captures, deletes and shares.
    """

    // MCP tool descriptions (same wording family as the guide).
    public static let toolRecent = "List the user's newest Capturist captures (screenshots, snippets, PDFs). \(summary)"
    public static let toolSearch = "Search the user's Capturist captures by words: file name, source app, window title and the text inside screenshots."
    public static let toolGet = "Get one capture by ref (latest, latest~1, or id prefix): returns details, the text inside it, and the image itself."
    public static let toolText = "Get only the text inside a capture (read on device). Best for errors, logs and code."
    public static let toolSaveSnippet = "Save text into the user's Capturist library (a summary, code, notes) when the user asks to keep, save or pin something to Capturist."
    public static let toolSaveImage = "Save an image or PDF into the user's Capturist library when the user asks to keep, save or pin it to Capturist."
    public static let toolClips = "List recent clipboard text the user copied (only if clipboard history is on in Capturist)."
}
