# zk-lsp.nvim

This context defines the note-workflow language used by the Neovim companion for the zettelkasten system.

## Language

**Companion Plugin**:
The Neovim-side interface for working with the note system. It assumes the note-system executable already exists and does not own that executable's installation.
_Avoid_: Compatibility layer, wrapper, server

**zk-lsp Executable**:
The external note-system program that owns note creation, indexing, formatting, graph checks, and LSP service behavior.
_Avoid_: Managed binary, bundled server

**Executable Configuration**:
The user-level and wiki-level TOML configuration consumed by the zk-lsp executable. It defines executable-owned note behavior such as note templates, declared custom metadata, hooks, and reconcile rules.
_Avoid_: Plugin config, Neovim config

**Metadata Schema**:
The executable-reported set of core and configured custom note metadata fields, including field kinds, defaults, and source configuration files.
_Avoid_: Form schema, search fields, TOML parser output

**Wiki**:
The local zettelkasten workspace that contains the note corpus and shared note assets.
_Avoid_: Vault, project, repository

**Note**:
A single zettelkasten entry in the wiki, identified by a stable numeric note ID.
_Avoid_: File, document, page

**Note Reference**:
An inline reference from one note to another note by numeric note ID.
_Avoid_: Link, backlink, citation

**Capture**:
A workflow that turns an external source, selected text, or local artifact into a new note or note-ready payload.
_Avoid_: Import, clipping, scrape

**Browser Capture**:
A capture workflow for recording a web page or browser-accessible PDF as note material.
_Avoid_: Zotero-like capture, Chrome capture, web clipping

**PDF Asset**:
A PDF artifact stored with the wiki as source material for a captured note.
_Avoid_: Attachment, download, binary blob

**Selection Capture**:
A capture workflow for turning an editor selection into a note-ready payload that preserves source context.
_Avoid_: Screenshot capture, yank capture

**Search Provider**:
A source of searchable note attributes that contributes to note filtering and display. The executable-backed provider is the default source, while local providers may add attributes discovered from wiki files.
_Avoid_: Parser, backend, indexer

## Decisions

- The plugin does not install or manage the `zk-lsp` executable. Users configure `executable`, defaulting to `zk-lsp`.
- `setup()` owns the canonical `:Zk` command tree, search, capture, browser host installation, and note-reference extmarks. It does not configure LSP clients, formatters, or keymaps.
- Search is provider-based. Executable note info is primary; local Lua providers may add structured fields such as local tags. Picker UI is currently Snacks-only.
- Capture creates notes through `zk-lsp new --json`, then normalizes the generated note so captured title/content are present even when the user's note template does not render those JSON fields. The plugin filters capture metadata through the executable-reported metadata schema and does not parse `zk-lsp.toml` itself.
- `schema-version` is executable-owned output metadata. The plugin does not send it as `new --json` input.
- Browser Capture ships as an unpacked Chrome extension plus a Native Messaging host. The extension downloads browser-accessible PDFs with Chrome and sends the completed file path to a one-shot headless Neovim host.
- Browser page capture sends page metadata from Chrome; the native host does not fetch browser URLs. Manual web capture and paper URL capture may still fetch URLs with `curl`.
- Captured PDF note metadata records both the source URL and the wiki-relative PDF asset path in `user.source` when both exist.
- Bibliography support is internal to capture. A Zotero-like translator layer enriches paper captures from explicit BibTeX, arXiv IDs, DOI/Crossref, generic citation metadata, and optional PDF text identifiers before falling back to a minimal entry. Missing `ref.bib` is created, and the default declaration is appended to `index.typ` as `#bibliography("ref.bib")`.
- ADR notes are local planning artifacts and are intentionally not tracked by git.
