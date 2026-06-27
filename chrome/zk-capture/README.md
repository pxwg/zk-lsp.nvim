# ZK Capture Chrome Extension

Load this directory as an unpacked Chrome extension, then run:

```vim
:Zk capture install-native-host {extension_id}
```

The extension downloads PDFs in Chrome and sends the completed local file path to the Neovim native host. Web page capture sends page metadata directly; the host does not fetch browser pages again.
