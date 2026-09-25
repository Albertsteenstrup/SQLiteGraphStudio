#!/usr/bin/env bash
# Canonical app identity and versions live in the source Info.plist.
SGS_METADATA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SGS_SOURCE_PLIST="$SGS_METADATA_ROOT/Sources/SQLiteGraphStudio/App/Info.plist"

sgs_metadata() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$SGS_SOURCE_PLIST"
}

sgs_write_metadata() {
    cp "$SGS_SOURCE_PLIST" "$1"
    plutil -lint "$1" >/dev/null
}

# Replacing a bundle while either its UI or MCP helper is executing can break
# other coding sessions. Check the exact bundle path; never signal processes by
# executable name, because that would hit unrelated worktrees and /Applications.
sgs_assert_bundle_not_running() {
    local app_bundle="$1"
    local process_name pid executable
    for process_name in SQLiteGraphStudio StudioMCP; do
        while IFS= read -r pid; do
            [[ -n "$pid" ]] || continue
            executable="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
            case "$executable" in
                "$app_bundle"/Contents/MacOS/*)
                    echo "Cannot replace $app_bundle while $process_name (PID $pid) is running from it. Close that copy or MCP session, then retry." >&2
                    return 1
                    ;;
            esac
        done < <(pgrep -x "$process_name" 2>/dev/null || true)
    done
}

sgs_open_reusing_running_app() {
    local requested_bundle="$1"
    local pid executable running_bundle
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        executable="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
        case "$executable" in
            */Contents/MacOS/SQLiteGraphStudio)
                running_bundle="${executable%/Contents/MacOS/SQLiteGraphStudio}"
                if [[ -d "$running_bundle" ]]; then
                    /usr/bin/open -a "$running_bundle"
                    return
                fi
                ;;
        esac
    done < <(pgrep -x SQLiteGraphStudio 2>/dev/null || true)
    /usr/bin/open -a "$requested_bundle"
}
