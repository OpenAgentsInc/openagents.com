#!/bin/bash
#
# OpenAgents CLI installer — https://openagents.com/install.sh
#
# Usage:
#   curl -fsSL https://openagents.com/install.sh | bash            # latest stable
#   curl -fsSL https://openagents.com/install.sh | bash -s 0.1.0   # specific version
#
# Windows: run under Git for Windows / MSYS2 Bash; WSL uses the Linux binary.

set -e

TARGET="$1"

if [[ -n "$TARGET" ]] && [[ ! "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._]+)?$ ]]; then
    echo "Invalid version format: $TARGET (expected X.Y.Z or X.Y.Z-suffix)" >&2
    exit 1
fi

DOWNLOADER=""
if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
else
    echo "Either curl or wget is required but neither is installed" >&2
    exit 1
fi

download_file() {
    local url="$1" output="$2"
    if [ "$DOWNLOADER" = "curl" ]; then
        if [ -n "$output" ]; then
            curl -fsSL -o "$output" "$url"
        else
            curl -fsSL "$url"
        fi
    else
        if [ -n "$output" ]; then
            wget -q -O "$output" "$url"
        else
            wget -q -O - "$url"
        fi
    fi
}

download_file_parallel() {
    local url="$1" output="$2"
    if [ "$DOWNLOADER" != "curl" ]; then
        download_file "$url" "$output"
        return
    fi
    local size
    size=$(curl -fsSL --head "$url" 2>/dev/null | awk -F'[: \r\n]+' 'tolower($1)=="content-length"{print $2; exit}')
    if [ -z "$size" ] || ! [ "$size" -ge 16777216 ] 2>/dev/null; then
        download_file "$url" "$output"
        return
    fi
    local n=8
    local chunk_size=$(( (size + n - 1) / n ))
    local tmpdir
    tmpdir=$(mktemp -d 2>/dev/null) || { download_file "$url" "$output"; return; }
    local pids=() i start end
    for i in $(seq 0 $((n - 1))); do
        start=$((i * chunk_size))
        end=$((start + chunk_size - 1))
        [ $end -ge $size ] && end=$((size - 1))
        curl -fsSL -r "${start}-${end}" -o "${tmpdir}/$(printf 'chunk.%03d' "$i")" "$url" &
        pids+=($!)
    done
    local all_ok=true pid
    for pid in "${pids[@]}"; do
        wait "$pid" || all_ok=false
    done
    if [ "$all_ok" = true ] && cat "${tmpdir}"/chunk.* > "$output" 2>/dev/null; then
        rm -rf "$tmpdir"
        return 0
    fi
    rm -rf "$tmpdir"
    download_file "$url" "$output"
}

is_not_found() {
    local url="$1" code
    if [ "$DOWNLOADER" = "curl" ]; then
        code=$(curl -o /dev/null -sSL -w '%{http_code}' --head "$url" 2>/dev/null) || true
    else
        code=$(wget --server-response --spider "$url" 2>&1 | awk '/HTTP\//{print $2}' | tail -1) || true
    fi
    [ "$code" = "404" ]
}

case "$(uname -s)" in
    Darwin) os="macos" ;;
    Linux)  os="linux" ;;
    MINGW* | MSYS* | CYGWIN*) os="windows" ;;
    *)      echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
    x86_64|amd64|AMD64) arch="x86_64" ;;
    arm64|aarch64|ARM64) arch="aarch64" ;;
    *)                    echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# Rosetta shell translation detection on Apple Silicon
if [ "$os" = "macos" ] && [ "$arch" = "x86_64" ]; then
    sysctl_bin="$(command -v sysctl || echo /usr/sbin/sysctl)"
    if [ "$("$sysctl_bin" -n hw.optional.arm64 2>/dev/null)" = "1" ]; then
        echo "Apple Silicon detected (Rosetta shell); installing the native arm64 build." >&2
        arch="aarch64"
    fi
fi

BASE_URL_PRIMARY="https://openagents.com/releases"
DOWNLOAD_DIR="$HOME/.openagents/downloads"
BIN_DIR="${OPENAGENTS_BIN_DIR:-$HOME/.openagents/bin}"
mkdir -p "$DOWNLOAD_DIR" "$BIN_DIR"

platform="${os}-${arch}"
CHANNEL="${OPENAGENTS_CHANNEL:-stable}"

# A channel is a pointer file naming the version it currently means, so
# `stable` can move without every installed script having to. A hardcoded
# default would make the channel a decoration: it was read and then ignored.
if [ -n "$TARGET" ]; then
    version="$TARGET"
else
    version="$(download_file "${BASE_URL_PRIMARY}/${CHANNEL}" "" 2>/dev/null | tr -d '[:space:]')" || version=""
    if [ -z "$version" ]; then
        echo "Could not resolve the '${CHANNEL}' channel from ${BASE_URL_PRIMARY}/${CHANNEL}." >&2
        echo "Pass a version explicitly: curl -fsSL https://openagents.com/install.sh | bash -s X.Y.Z" >&2
        exit 1
    fi
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._]+)?$ ]]; then
        echo "The '${CHANNEL}' channel returned something that is not a version: ${version}" >&2
        exit 1
    fi
fi

echo "Installing OpenAgents CLI $version ($platform)..." >&2

binary_path="$DOWNLOAD_DIR/openagents-$platform"
artifact_base="${BASE_URL_PRIMARY}/openagents-${version}-${platform}"

if [ "$os" = "windows" ]; then
    binary_path="${binary_path}.exe"
fi

binary_tmp="${binary_path}.tmp.$$"
rm -f "$binary_tmp" 2>/dev/null || true

# The download is the only source. This used to fall back to `./target/debug/oa`
# or an already-installed binary when the fetch failed, which meant running the
# installer from any directory holding a stale or foreign build silently
# installed that build while printing the version it meant to fetch. An
# installer people pipe into bash cannot have a path that installs something
# nobody named.
if ! download_file_parallel "$artifact_base" "$binary_tmp" 2>/dev/null; then
    echo "Could not download ${artifact_base}." >&2
    echo "No local fallback is used: an installer must install what it says it did." >&2
    exit 1
fi
echo "  Downloaded openagents ${version}." >&2

# Verify before the bytes are ever made executable. A checksum fetched over the
# same connection as the artifact proves only that they arrived together, which
# is why the sums file is fetched separately and the artifact is refused when it
# is absent rather than installed unverified.
checksum_tool=""
if command -v shasum >/dev/null 2>&1; then
    checksum_tool="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
    checksum_tool="sha256sum"
else
    echo "Neither shasum nor sha256sum is available; refusing to install unverified bytes." >&2
    rm -f "$binary_tmp"
    exit 1
fi

sums_tmp="${binary_tmp}.sums"
if ! download_file "${BASE_URL_PRIMARY}/SHA256SUMS-${version}" "$sums_tmp" 2>/dev/null; then
    echo "Could not download SHA256SUMS-${version}; refusing to install unverified bytes." >&2
    rm -f "$binary_tmp" "$sums_tmp"
    exit 1
fi

artifact_name="openagents-${version}-${platform}"
[ "$os" = "windows" ] && artifact_name="${artifact_name}.exe"

expected="$(awk -v name="$artifact_name" '$2 == name || $2 == "*" name { print $1 }' "$sums_tmp" | head -1)"
if [ -z "$expected" ]; then
    echo "SHA256SUMS-${version} names no entry for ${artifact_name}; refusing to install." >&2
    rm -f "$binary_tmp" "$sums_tmp"
    exit 1
fi

actual="$($checksum_tool "$binary_tmp" | awk '{ print $1 }')"
if [ "$actual" != "$expected" ]; then
    echo "Checksum mismatch for ${artifact_name}." >&2
    echo "  expected ${expected}" >&2
    echo "  actual   ${actual}" >&2
    rm -f "$binary_tmp" "$sums_tmp"
    exit 1
fi
rm -f "$sums_tmp"
echo "  Verified sha256 ${actual}." >&2

if [ "$os" = "windows" ]; then
    mv -f "$binary_tmp" "$binary_path"
    for bin_name in openagents.exe oa.exe; do
        rm -f "$BIN_DIR/$bin_name.old" 2>/dev/null || true
        cp -f "$binary_path" "$BIN_DIR/$bin_name" 2>/dev/null || true
    done
    echo "  Binary installed to $BIN_DIR/openagents.exe and $BIN_DIR/oa.exe." >&2
else
    chmod +x "$binary_tmp"
    mv -f "$binary_tmp" "$binary_path"

    if [ "$(dirname "$BIN_DIR")" = "$(dirname "$DOWNLOAD_DIR")" ]; then
        link_target="../$(basename "$DOWNLOAD_DIR")/$(basename "$binary_path")"
    else
        link_target="$binary_path"
    fi
    ln -sf "$link_target" "$BIN_DIR/openagents"
    ln -sf "$link_target" "$BIN_DIR/oa"
    echo "  Binary linked to $BIN_DIR/openagents and $BIN_DIR/oa." >&2
fi

path_has_dir() {
    case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac
}

SYMLINK_CREATED=""
if [ "$os" != "windows" ] && ! path_has_dir "$BIN_DIR"; then
    for candidate in "$HOME/.local/bin" "/usr/local/bin"; do
        if path_has_dir "$candidate" && [ -d "$candidate" ] && [ -w "$candidate" ]; then
            ln -sf "$BIN_DIR/openagents" "$candidate/openagents"
            ln -sf "$BIN_DIR/oa" "$candidate/oa"
            SYMLINK_CREATED="$candidate"
            echo "  Symlinked $candidate/openagents -> $BIN_DIR/openagents" >&2
            echo "  Symlinked $candidate/oa -> $BIN_DIR/oa" >&2
            break
        fi
    done
fi

user_shell="$(basename "${SHELL:-}")"
config_file=""

case "$user_shell" in
    bash) config_file="$HOME/.bashrc" ;;
    zsh)  config_file="$HOME/.zshrc" ;;
    fish) config_file="$HOME/.config/fish/config.fish" ;;
esac

if [ -n "$config_file" ]; then
    mkdir -p "$(dirname "$config_file")"

    if [ "$user_shell" = "fish" ]; then
        new_block='# >>> openagents installer >>>
fish_add_path $HOME/.openagents/bin
# <<< openagents installer <<<'
    else
        new_block='# >>> openagents installer >>>
export PATH="$HOME/.openagents/bin:$PATH"
# <<< openagents installer <<<'
    fi

    if grep -qs "openagents installer" "$config_file" 2>/dev/null; then
        tmp="$config_file.tmp.$$"
        awk '
            /# >>> openagents installer >>>/ { skip=1; next }
            /# <<< openagents installer <<</ { skip=0; next }
            !skip { print }
        ' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
    else
        [ -f "$config_file" ] && cp "$config_file" "$config_file.bak.$(date +%s)"
    fi

    printf '\n%s\n' "$new_block" >> "$config_file"
    echo "  Updated $BIN_DIR in PATH in $config_file." >&2
fi

echo "" >&2
echo "OpenAgents CLI $version installation complete!" >&2
echo "Run 'openagents' or 'oa' to get started." >&2
