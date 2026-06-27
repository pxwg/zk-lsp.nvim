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
