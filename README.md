# towebp

Batch convert images to WebP -- CLI + macOS app.

## CLI

### Install

```bash
npm install -g towebp
```

Or clone and link locally for development:

```bash
git clone https://github.com/keiver/towebp.git
cd towebp
npm install && npm run build && npm link
```

### Usage

```bash
# Convert a single file (output next to source)
towebp photo.png

# Convert all images in a directory (output next to sources)
towebp images/

# Convert to a separate output directory
towebp images/ output/

# Custom quality (1-100, default: 90)
towebp -q 80 photo.png

# Recursive subdirectory processing
towebp -r images/
```

### Options

| Flag | Description |
|------|-------------|
| `-q, --quality <n>` | WebP quality 1-100 (default: 90) |
| `-r, --recursive` | Process subdirectories recursively |
| `-h, --help` | Show help message |
| `-v, --version` | Show version number |

### Features

- Skips files that haven't changed (compares mtime)
- Atomic writes via temp directory
- Concurrent processing (up to 4 workers)
- Color space conversion (display-p3 / RGB to sRGB)
- Auto-rotation based on EXIF data
- Same-directory output by default
- Recursive subdirectory support with mirrored structure

### Supported Formats

JPG, JPEG, PNG, GIF, BMP, TIFF, WebP

## macOS App

Native SwiftUI GUI that wraps the CLI. Drag and drop images or folders to convert them.

### Requirements

- macOS 14+
- Swift 5.10+
- The `towebp` CLI must be installed (see above)

### Run in development

```bash
cd app
swift run
```

### Install to /Applications

```bash
cd app
./install-app.sh
```

This builds a release binary, creates an app bundle at `/Applications/ToWebP.app`, and signs it locally.

### App Features

- Drag-and-drop files and folders
- File picker dialog
- Quality slider (1-100)
- Recursive toggle
- Live progress tracking with cancel support
- Always-on-top floating window
- Menu bar icon with quick access
- Launch at login option
- Install to /Applications from the menu bar

## Finder Quick Action

You can set up a right-click "Convert to WebP" action in Finder:

1. Open **Automator** and create a new **Quick Action**
2. Set "Workflow receives current" to **files or folders** in **Finder**
3. Add a **Run Shell Script** action
4. Set "Pass input" to **as arguments**
5. Paste the contents of `quickaction/convert-to-webp.sh` or reference it directly:

```bash
/bin/bash /path/to/towebp/quickaction/convert-to-webp.sh "$@"
```

6. Save as "Convert to WebP"

Now you can right-click any image or folder in Finder and select **Quick Actions > Convert to WebP**.

## Requirements

| Component | Requires |
|-----------|----------|
| CLI | Node.js 18+, Sharp |
| macOS App | macOS 14+, Swift 5.10+ |

## License

MIT
