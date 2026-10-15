#!/bin/sh
set -eu

# Runtime Finder icons must be removed from build products before Xcode signs them again.
app="$1"
if [ -d "$app" ]; then
    if /usr/bin/xattr -p com.apple.FinderInfo "$app" >/dev/null 2>&1; then
        /usr/bin/xattr -d com.apple.FinderInfo "$app"
    fi
    /bin/rm -f "$app/Icon$(printf '\r')"
fi
