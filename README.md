# scan_arch.sh

`scan_arch.sh` is a bash script that scans a specified folder (including all subfolders) on macOS for `.app` bundles and prints the architectures of their main executables.

## Features

- Recursively detects all `.app` bundles.
- Determines the main executable via `CFBundleExecutable` or falls back to the first Mach-O binary.
- Detects architectures: `arm64`, `x86_64`, `i386`, and unknown binaries.
- Deduplicates apps by name to avoid repeated entries.
- Color-coded output to indicate compatibility:
  - Green: fully compatible with host
  - Yellow: partially compatible / legacy
  - Red: incompatible or unsupported
  - Blue: unknown binary
- Sorts architectures according to host compatibility.
- Compatible with ARM, Intel, and 32-bit-only Macs.

## Usage

```bash
chmod +x scan_arch.sh
./scan_arch.sh /path/to/folder
```

## Example Output

```
Cyberpunk2077 → arm64
Castle Crashers → x86_64, arm64
Postal 1 → i386
Terraria → Unknown
```

## Notes

- Run the script in `bash` (default macOS shell is zsh; use `#!/usr/bin/env bash`).
- The script auto-detects host architecture and macOS version to adjust color coding and architecture order.
- Unknown or helper binaries are displayed in blue.

