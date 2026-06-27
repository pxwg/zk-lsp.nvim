# zk-lsp.nvim

Neovim companion plugin for a `zk-lsp` Typst wiki.

This plugin owns Neovim workflows around the executable: `:Zk` commands, Snacks search, capture, Browser Capture, bibliography helpers, health checks, and note-reference extmarks. It does not install `zk-lsp`, configure an LSP client, configure a formatter, or define keymaps.

## Requirements

- Neovim 0.12+
- A user-installed `zk-lsp` executable with `notes --json` support. The default command is `zk-lsp`.
- Optional: `folke/snacks.nvim` for `:Zk search`.
- Optional: `curl` for manual web capture and paper URL capture.

## Install

Example with `lazy.nvim`:

```lua
local zk_opts = {
  executable = "zk-lsp",
  wiki_root = vim.env.WIKI_ROOT or vim.fn.expand("~/wiki"),
}

return {
  "pxwg/zk-lsp.nvim",
  dependencies = {
    "folke/snacks.nvim",
  },
  build = function()
    require("zk_lsp").build(zk_opts)
  end,
  config = function()
    require("zk_lsp").setup(zk_opts)
  end,
}
```

`build()` prepares the native-host launcher/config used by Browser Capture. The Chrome manifest still has to be installed with `:Zk capture install-native-host {extension_id}` because Chrome assigns the extension ID after loading the unpacked extension.

## Configuration

Defaults:

```lua
require("zk_lsp").setup({
  executable = "zk-lsp",
  wiki_root = nil, -- opts.wiki_root -> WIKI_ROOT -> ~/wiki
  search = {
    enabled = true,
    picker = "snacks",
    providers = {
      local_note = true,
    },
  },
  capture = {
    enabled = true,
    fetch = {
      manual = true,
      browser = false,
      paper = true,
    },
    bibliography = {
      path = "ref.bib",
      declare = {
        enabled = true,
        file = "index.typ",
      },
    },
    browser = {
      enabled = true,
      host_name = "top.homeward_sky.zk_capture",
    },
    templates = {},
  },
  extmark = {
    enabled = true,
    conceal = true,
    hl_group = "Identifier",
  },
})
```

The plugin asks the executable for metadata fields with:

```sh
zk-lsp config metadata fields --json --sources
```

Capture filters metadata through that schema. Unknown fields are skipped with a warning instead of being written into new notes.

Search asks the executable for canonical note records with:

```sh
zk-lsp notes --json
```

There is no local metadata parser fallback. Older `zk-lsp` binaries without this command will fail `:checkhealth zk_lsp` and `:Zk search`.

## Commands

Canonical command tree:

```vim
:Zk new
:Zk remove [id]
:Zk export {id} [--depth N] [--inverse] [--simple]
:Zk generate
:Zk reconcile [--dry-run]
:Zk check [--no-orphans] [--no-dead-links]

:Zk search
:Zk search alias
:Zk search keyword
:Zk search abstract
:Zk search tag
:Zk search todo
:Zk search done
:Zk search orphans

:Zk capture
:Zk capture web
:Zk capture paper
:Zk capture paper-note {bibkey}
:Zk capture extension-path
:Zk capture install-native-host {extension_id}
```

Old flat aliases such as `:Zk paper-note` are intentionally not provided.

## LSP Sample

LSP setup belongs in the user's config. See the executable project at <https://github.com/pxwg/zk-lsp.typ> for the `zk-lsp` server itself.

Example:

```lua
vim.lsp.config("zk-lsp", {
  cmd = { "zk-lsp", "--wiki-root", vim.fn.expand("~/wiki"), "lsp" },
  filetypes = { "typst" },
  root_markers = { "zk-lsp.toml", ".git" },
  offset_encoding = "utf-16",
})

vim.lsp.enable("zk-lsp")
```

Formatter setup is also left to user config.

## Keymap Sample

The plugin does not install keymaps. A compact sample matching the old personal workflow:

```lua
vim.keymap.set("n", "zn", "<cmd>Zk new<cr>", { desc = "[Z]ettel [N]ew" })
vim.keymap.set("n", "zs", "<cmd>Zk search<cr>", { desc = "[Z]ettel [S]earch" })
vim.keymap.set("n", "<leader>fz", "<cmd>Zk search<cr>", { desc = "[F]ind [Z]ettel" })
vim.keymap.set("n", "zt", "<cmd>Zk search todo<cr>", { desc = "[Z]ettel [T]ODO Search" })
vim.keymap.set("n", "<leader>fo", "<cmd>Zk search orphans<cr>", { desc = "[F]ind [O]rphan Zettels" })

vim.keymap.set("n", "ze", function()
  local id = vim.fn.expand("<cword>")
  vim.cmd("Zk export " .. id .. " --depth 5 --inverse")
end, { desc = "[Z]ettel [E]xport" })

vim.keymap.set("n", "zr", function()
  vim.cmd("Zk remove " .. vim.fn.expand("<cword>"))
end, { desc = "[Z]ettel [R]emove" })
```

## Search Providers

Executable `notes --json` is the primary source. The built-in `local_note` provider adds local tags such as `#tag.foo`, note titles, and references discovered from wiki files.

Users can add Lua providers:

```lua
require("zk_lsp").setup({
  search = {
    providers = {
      local_note = true,
      function()
        return {
          name = "project_tags",
          enrich = function(note)
            if note.path and note.path:match("/project/") then
              return {
                tags = { "project" },
                metadata = {
                  ["user.project"] = "default",
                },
              }
            end
          end,
        }
      end,
    },
  },
})
```

Provider `tags` are top-level search/filter tags. Provider metadata is merged with executable metadata; conflicts are namespaced under the provider name.

## Capture

All note creation goes through `zk-lsp new --json`.

### Web

```vim
:Zk capture web
:Zk capture web https://example.com
```

Manual web capture may fetch the page with `curl` when `capture.fetch.manual = true`. Browser Capture does not fetch the URL in the native host.

### Paper

```vim
:Zk capture paper
:Zk capture paper ~/Downloads/paper.pdf
:Zk capture paper https://example.com/paper.pdf
:Zk capture paper-note someBibKey
```

If `ref.bib` does not exist, it is created. By default the plugin appends:

```typst
#bibliography("ref.bib")
```

to `index.typ` if the declaration is missing.

PDF files are copied or moved into:

```text
assets/{note-id}-pdf/
```

and the BibTeX entry receives a `file = {...}` field pointing at the wiki-relative asset path.

### Browser Capture

The Chrome extension is shipped in this repository under `chrome/zk-capture`.

1. Run `:Zk capture extension-path` and load the copied path in `chrome://extensions` with "Load unpacked".
2. Copy the extension ID from Chrome.
3. Run `:Zk capture install-native-host {extension_id}`.
4. Use the extension popup or context menus.

For PDFs, Chrome performs the download with the browser session/cookies, then sends the completed local file path to a one-shot headless Neovim native host. The host moves the file into wiki assets and creates the note.

For pages, Chrome extracts page metadata and sends it to the host. The host does not fetch the browser URL again.

## Capture Hooks

Capture templates can be extended in Lua:

```lua
require("zk_lsp").setup({
  capture = {
    templates = {
      web = {
        pre_create = function(ctx)
          return {
            note = {
              metadata = {
                ["user.project"] = "inbox",
              },
            },
          }
        end,
        post_create = function(ctx)
          vim.notify("captured " .. ctx.result.note_path)
        end,
      },
    },
  },
})
```

Returned metadata still goes through executable schema filtering.

## Health

```vim
:checkhealth zk_lsp
```

The healthcheck verifies Neovim version, executable availability, metadata schema access, wiki directories, Snacks, curl, and Chrome extension assets.
