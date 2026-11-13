#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="${BROWSER_SDK:-$(xcrun --show-sdk-path)}"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    SDK="${BROWSER_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
fi
ARCH="${BROWSER_ARCH:-$(uname -m)}"
OUT="${BROWSER_OUTPUT:-build/Alcove.app}"
MANUAL="$PWD/.build/manual/$ARCH"
FLAGS=(-sdk "$SDK" -module-cache-path "$PWD/.build/cache" -target "$ARCH-apple-macosx14.0")
mkdir -p "$MANUAL" "$OUT/Contents/MacOS"
xcrun swiftc "${FLAGS[@]}" -emit-module -emit-library -enable-testing -module-name BrowserCore Sources/BrowserCore/*.swift -o "$MANUAL/libBrowserCore.dylib" -emit-module-path "$MANUAL/BrowserCore.swiftmodule"
STORE_SOURCES=()
for source in Sources/Browser/*.swift; do [[ "$source" == "Sources/Browser/main.swift" ]] || STORE_SOURCES+=("$source"); done
SIDEBAR_SOURCES=()
for source in Sources/Browser/SidebarInteraction.swift Sources/Browser/SidebarRevealController.swift Sources/Browser/SidebarTracking.swift; do
    [[ ! -f "$source" ]] || SIDEBAR_SOURCES+=("$source")
done
run_website_checks() {
    if [[ "${1:-}" != "quick-website-test" ]]; then
        xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/ProfileWebsiteChecks.swift -o "$MANUAL/profile-website-checks"
    fi
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/QuickBrowseWebsiteChecks.swift scripts/OwnedWebsiteStores.swift -o "$MANUAL/quick-website-checks"
    FIXTURE_PORT_FILE="$(mktemp "$MANUAL/profile-fixture.XXXXXX")"
    python3 scripts/ProfileFixture.py "$FIXTURE_PORT_FILE" > "$MANUAL/profile-fixture.log" 2>&1 &
    FIXTURE_PID=$!
    trap 'kill "$FIXTURE_PID" 2>/dev/null || true; wait "$FIXTURE_PID" 2>/dev/null || true; rm -f "$FIXTURE_PORT_FILE"' EXIT
    for attempt in {1..500}; do [[ -s "$FIXTURE_PORT_FILE" ]] && break; kill -0 "$FIXTURE_PID" 2>/dev/null || break; sleep 0.02; done
    [[ -s "$FIXTURE_PORT_FILE" ]] || { cat "$MANUAL/profile-fixture.log"; exit 1; }
    if [[ "${1:-}" != "quick-website-test" ]]; then
        ALCOVE_PROFILE_FIXTURE_URL="http://127.0.0.1:$(cat "$FIXTURE_PORT_FILE")/" "$MANUAL/profile-website-checks"
    fi
    ALCOVE_PROFILE_FIXTURE_URL="http://127.0.0.1:$(cat "$FIXTURE_PORT_FILE")/" "$MANUAL/quick-website-checks"
    kill "$FIXTURE_PID" 2>/dev/null || true
    wait "$FIXTURE_PID" 2>/dev/null || true
    rm -f "$FIXTURE_PORT_FILE"
    trap - EXIT

}
run_site_search_checks() {
    local mode="$1"
    if [[ "$mode" == "store" ]]; then
        xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/SiteSearchFixtures.swift scripts/SiteSearchStoreChecks.swift -o "$MANUAL/site-search-store-checks"
    else
        xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/SiteSearchWebsiteChecks.swift scripts/OwnedWebsiteStores.swift -o "$MANUAL/site-search-website-checks"
    fi
    local search_port_file
    search_port_file="$(mktemp "$MANUAL/site-search-port.XXXXXX")"
    python3 scripts/SiteSearchFixture.py "$search_port_file" > "$MANUAL/site-search-fixture.log" 2>&1 &
    local search_fixture_pid=$!
    trap 'kill "$search_fixture_pid" 2>/dev/null || true; wait "$search_fixture_pid" 2>/dev/null || true; rm -f "$search_port_file"' EXIT
    for attempt in {1..500}; do [[ -s "$search_port_file" ]] && break; kill -0 "$search_fixture_pid" 2>/dev/null || break; sleep 0.02; done
    [[ -s "$search_port_file" ]]
    ALCOVE_SITE_SEARCH_FIXTURE_URL="http://127.0.0.1:$(cat "$search_port_file")/" "$MANUAL/site-search-$mode-checks"
    kill "$search_fixture_pid" 2>/dev/null || true
    wait "$search_fixture_pid" 2>/dev/null || true
    rm -f "$search_port_file"
    trap - EXIT
}
run_link_routing_website_checks() {
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/LinkRoutingWebsiteChecks.swift scripts/OwnedWebsiteStores.swift -o "$MANUAL/link-routing-website-checks"
    local routing_port_file routing_fixture_pid
    routing_port_file="$(mktemp "$MANUAL/link-routing-port.XXXXXX")"
    python3 scripts/LinkRoutingFixture.py "$routing_port_file" > "$MANUAL/link-routing-fixture.log" 2>&1 &
    routing_fixture_pid=$!
    trap 'kill "$routing_fixture_pid" 2>/dev/null || true; wait "$routing_fixture_pid" 2>/dev/null || true; rm -f "$routing_port_file"' EXIT
    for attempt in {1..500}; do [[ -s "$routing_port_file" ]] && break; kill -0 "$routing_fixture_pid" 2>/dev/null || break; sleep 0.02; done
    [[ -s "$routing_port_file" ]]
    ALCOVE_LINK_ROUTING_FIXTURE_URL="http://127.0.0.1:$(cat "$routing_port_file")/" "$MANUAL/link-routing-website-checks"
    kill "$routing_fixture_pid" 2>/dev/null || true
    wait "$routing_fixture_pid" 2>/dev/null || true
    rm -f "$routing_port_file"
    trap - EXIT
}
run_boosts_website_checks() {
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/SiteSearchFixtures.swift scripts/BoostWebsiteChecks.swift -o "$MANUAL/boosts-website-checks"
    local boost_port_file boost_fixture_pid
    boost_port_file="$(mktemp "$MANUAL/boost-port.XXXXXX")"
    python3 scripts/BoostFixture.py "$boost_port_file" > "$MANUAL/boost-fixture.log" 2>&1 &
    boost_fixture_pid=$!
    trap 'kill "$boost_fixture_pid" 2>/dev/null || true; wait "$boost_fixture_pid" 2>/dev/null || true; rm -f "$boost_port_file"' EXIT
    for attempt in {1..500}; do [[ -s "$boost_port_file" ]] && break; kill -0 "$boost_fixture_pid" 2>/dev/null || break; sleep 0.02; done
    [[ -s "$boost_port_file" ]]
    ALCOVE_BOOST_FIXTURE_URL="http://127.0.0.1:$(cat "$boost_port_file")/" "$MANUAL/boosts-website-checks"
    kill "$boost_fixture_pid" 2>/dev/null || true
    wait "$boost_fixture_pid" 2>/dev/null || true
    rm -f "$boost_port_file"
    trap - EXIT
}
run_extension_core_checks() {
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" scripts/ExtensionCoreChecks.swift scripts/ExtensionManifestChecks.swift scripts/ExtensionZIPChecks.swift scripts/ExtensionPackageChecks.swift scripts/ExtensionCRXChecks.swift scripts/ExtensionStoreLocationChecks.swift -o "$MANUAL/extension-core-checks"
    "$MANUAL/extension-core-checks"
}
if [[ "${1:-}" == "extension-core-test" ]]; then run_extension_core_checks; exit; fi
run_extension_download_checks() {
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" Sources/Browser/ExtensionStoreDownload.swift scripts/ExtensionDownloadChecks.swift scripts/ExtensionZIPChecks.swift scripts/ExtensionCRXChecks.swift -o "$MANUAL/extension-download-checks"
    "$MANUAL/extension-download-checks"
}
if [[ "${1:-}" == "extension-download-test" ]]; then run_extension_download_checks; exit; fi
run_extension_store_checks() {
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/ExtensionStoreChecks.swift scripts/OwnedWebsiteStores.swift scripts/OwnedExtensionControllers.swift scripts/ExtensionZIPChecks.swift scripts/ExtensionCRXChecks.swift -o "$MANUAL/extension-store-checks"
    "$MANUAL/extension-store-checks"
}
if [[ "${1:-}" == "extension-store-test" ]]; then run_extension_store_checks; exit; fi
run_extension_runtime_checks() {
    local extension_check_name="${1:-runtime}" extension_check_source="scripts/ExtensionRuntimeChecks.swift"
    if [[ "$extension_check_name" == "navigation" ]]; then extension_check_source="scripts/ExtensionNavigationChecks.swift"; fi
    if [[ "$extension_check_name" == "adapter" ]]; then extension_check_source="scripts/ExtensionAdapterChecks.swift"; fi
    if [[ "$extension_check_name" == "private" ]]; then extension_check_source="scripts/ExtensionPrivateChecks.swift"; fi
    if [[ "$extension_check_name" == "permission" ]]; then extension_check_source="scripts/ExtensionPermissionChecks.swift"; fi
    if [[ "$extension_check_name" == "action" ]]; then extension_check_source="scripts/ExtensionActionChecks.swift"; fi
    if [[ "$extension_check_name" == "command" ]]; then extension_check_source="scripts/ExtensionCommandChecks.swift"; fi
    if [[ "$extension_check_name" == "reopen" ]]; then extension_check_source="scripts/ExtensionReopenChecks.swift"; fi
    if [[ "$extension_check_name" == "surface" ]]; then extension_check_source="scripts/ExtensionSurfaceChecks.swift"; fi
    if [[ "$extension_check_name" == "erasure" ]]; then extension_check_source="scripts/ExtensionErasureChecks.swift"; fi
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" "$extension_check_source" scripts/OwnedWebsiteStores.swift scripts/OwnedExtensionControllers.swift -o "$MANUAL/extension-$extension_check_name-checks"
    local extension_port_file extension_fixture_pid
    extension_port_file="$(mktemp "$MANUAL/extension-port.XXXXXX")"
    python3 scripts/ExtensionFixture.py "$extension_port_file" > "$MANUAL/extension-fixture.log" 2>&1 &
    extension_fixture_pid=$!
    trap 'kill "$extension_fixture_pid" 2>/dev/null || true; wait "$extension_fixture_pid" 2>/dev/null || true; python3 -c "import pathlib,sys; pathlib.Path(sys.argv[1]).unlink(missing_ok=True)" "$extension_port_file"' EXIT
    for attempt in {1..500}; do [[ -s "$extension_port_file" ]] && break; kill -0 "$extension_fixture_pid" 2>/dev/null || break; sleep 0.02; done
    [[ -s "$extension_port_file" ]]
    ALCOVE_EXTENSION_FIXTURE_URL="http://127.0.0.1:$(cat "$extension_port_file")/" "$MANUAL/extension-$extension_check_name-checks"
    kill "$extension_fixture_pid" 2>/dev/null || true
    wait "$extension_fixture_pid" 2>/dev/null || true
    python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).unlink(missing_ok=True)' "$extension_port_file"
    trap - EXIT
}
if [[ "${1:-}" == "extension-runtime-test" ]]; then run_extension_runtime_checks; exit; fi
if [[ "${1:-}" == "extension-navigation-test" ]]; then run_extension_runtime_checks navigation; exit; fi
if [[ "${1:-}" == "extension-adapter-test" ]]; then run_extension_runtime_checks adapter; exit; fi
if [[ "${1:-}" == "extension-private-test" ]]; then run_extension_runtime_checks private; exit; fi
if [[ "${1:-}" == "extension-permission-test" ]]; then run_extension_runtime_checks permission; exit; fi
if [[ "${1:-}" == "extension-action-test" ]]; then run_extension_runtime_checks action; exit; fi
if [[ "${1:-}" == "extension-command-test" ]]; then run_extension_runtime_checks command; exit; fi
if [[ "${1:-}" == "extension-reopen-test" ]]; then run_extension_runtime_checks reopen; exit; fi
if [[ "${1:-}" == "extension-surface-test" ]]; then run_extension_runtime_checks surface; exit; fi
if [[ "${1:-}" == "extension-erasure-test" ]]; then run_extension_runtime_checks erasure; exit; fi
run_sidebar_organization_checks() {
    local sidebar_check_source="scripts/SidebarOrganizationChecks.swift" sidebar_check_binary="$MANUAL/sidebar-organization-checks"
    if [[ "${1:-}" == "layout" ]]; then sidebar_check_source="scripts/SidebarOrganizationLayoutChecks.swift"; sidebar_check_binary="$MANUAL/sidebar-organization-layout-checks"; fi
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" "$sidebar_check_source" -o "$sidebar_check_binary"
    local sidebar_port_file sidebar_fixture_pid
    sidebar_port_file="$(mktemp "$MANUAL/sidebar-port.XXXXXX")"
    python3 scripts/ExtensionFixture.py "$sidebar_port_file" > "$MANUAL/sidebar-fixture.log" 2>&1 &
    sidebar_fixture_pid=$!
    trap 'kill "$sidebar_fixture_pid" 2>/dev/null || true; wait "$sidebar_fixture_pid" 2>/dev/null || true; python3 -c "import pathlib,sys; pathlib.Path(sys.argv[1]).unlink(missing_ok=True)" "$sidebar_port_file"' EXIT
    for attempt in {1..500}; do [[ -s "$sidebar_port_file" ]] && break; kill -0 "$sidebar_fixture_pid" 2>/dev/null || break; sleep 0.02; done
    [[ -s "$sidebar_port_file" ]]
    ALCOVE_EXTENSION_FIXTURE_URL="http://127.0.0.1:$(cat "$sidebar_port_file")/" "$sidebar_check_binary"
    kill "$sidebar_fixture_pid" 2>/dev/null || true
    wait "$sidebar_fixture_pid" 2>/dev/null || true
    python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).unlink(missing_ok=True)' "$sidebar_port_file"
    trap - EXIT
}
if [[ "${1:-}" == "sidebar-organization-test" ]]; then run_sidebar_organization_checks; exit; fi
run_sidebar_organization_layout_checks() {
    run_sidebar_organization_checks layout
}
if [[ "${1:-}" == "sidebar-organization-layout-test" ]]; then run_sidebar_organization_layout_checks; exit; fi
run_spaces_layout_checks() {
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/SpacesLayoutChecks.swift -o "$MANUAL/spaces-layout-checks"
    "$MANUAL/spaces-layout-checks"
}
if [[ "${1:-}" == "spaces-layout-test" ]]; then run_spaces_layout_checks; exit; fi
run_space_checks() {
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/SpaceManagementChecks.swift scripts/OwnedExtensionControllers.swift -o "$MANUAL/space-checks"
    "$MANUAL/space-checks"
}
if [[ "${1:-}" == "space-test" ]]; then run_space_checks; exit; fi
run_writer_checks() {
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/WriterOwnershipChecks.swift -o "$MANUAL/writer-checks"
    "$MANUAL/writer-checks"
}
if [[ "${1:-}" == "writer-test" ]]; then run_writer_checks; exit; fi
run_startup_checks() {
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/StartupChecks.swift -o "$MANUAL/startup-checks"
    "$MANUAL/startup-checks"
}
if [[ "${1:-}" == "startup-test" ]]; then run_startup_checks; exit; fi
if [[ "${1:-}" == "store-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/StoreChecks.swift -o "$MANUAL/store-checks"
    "$MANUAL/store-checks"
    exit
fi
if [[ "${1:-}" == "boosts-input-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/SiteSearchFixtures.swift scripts/BoostInputChecks.swift -o "$MANUAL/boosts-input-checks"
    "$MANUAL/boosts-input-checks"
    exit
fi
if [[ "${1:-}" == "boosts-website-test" ]]; then run_boosts_website_checks; exit; fi
if [[ "${1:-}" == "boosts-store-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/SiteSearchFixtures.swift scripts/BoostStoreChecks.swift -o "$MANUAL/boosts-store-checks"
    "$MANUAL/boosts-store-checks"
    exit
fi
if [[ "${1:-}" == "boosts-core-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" scripts/BoostCoreChecks.swift -o "$MANUAL/boosts-core-checks"
    "$MANUAL/boosts-core-checks"
    exit
fi
if [[ "${1:-}" == "link-routing-input-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/SiteSearchFixtures.swift scripts/LinkRoutingInputChecks.swift -o "$MANUAL/link-routing-input-checks"
    "$MANUAL/link-routing-input-checks"
    exit
fi
if [[ "${1:-}" == "link-routing-website-test" ]]; then
    run_link_routing_website_checks
    exit
fi
if [[ "${1:-}" == "link-routing-store-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/SiteSearchFixtures.swift scripts/LinkRoutingStoreChecks.swift -o "$MANUAL/link-routing-store-checks"
    "$MANUAL/link-routing-store-checks"
    exit
fi
if [[ "${1:-}" == "link-routing-core-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" scripts/LinkRoutingCoreChecks.swift -o "$MANUAL/link-routing-core-checks"
    "$MANUAL/link-routing-core-checks"
    exit
fi
if [[ "${1:-}" == "site-search-input-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/SiteSearchFixtures.swift scripts/SiteSearchInputChecks.swift -o "$MANUAL/site-search-input-checks"
    "$MANUAL/site-search-input-checks"
    exit
fi
if [[ "${1:-}" == "site-search-website-test" ]]; then
    run_site_search_checks website
    exit
fi
if [[ "${1:-}" == "site-search-store-test" ]]; then
    run_site_search_checks store
    exit
fi
if [[ "${1:-}" == "site-search-core-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" scripts/SiteSearchCoreChecks.swift -o "$MANUAL/site-search-core-checks"
    "$MANUAL/site-search-core-checks"
    exit
fi
if [[ "${1:-}" == "page-output-lifetime-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/PageOutputFixtures.swift scripts/PageOutputLifetimeChecks.swift -o "$MANUAL/page-output-lifetime-checks"
    "$MANUAL/page-output-lifetime-checks"
    exit
fi
if [[ "${1:-}" == "page-output-website-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/PageOutputWebsiteChecks.swift -o "$MANUAL/page-output-website-checks"
    "$MANUAL/page-output-website-checks"
    exit
fi
if [[ "${1:-}" == "page-output-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/PageOutputFixtures.swift scripts/PageOutputChecks.swift -o "$MANUAL/page-output-checks"
    "$MANUAL/page-output-checks"
    exit
fi
if [[ "${1:-}" == "sidebar-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${SIDEBAR_SOURCES[@]}" scripts/SidebarInteractionChecks.swift -o "$MANUAL/sidebar-checks"
    "$MANUAL/sidebar-checks"
    exit
fi
if [[ "${1:-}" == "sidebar-layout-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/SidebarLayoutChecks.swift -o "$MANUAL/sidebar-layout-checks"
    "$MANUAL/sidebar-layout-checks"
    exit
fi
if [[ "${1:-}" == "chrome-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/ChromeChecks.swift -o "$MANUAL/chrome-checks"
    "$MANUAL/chrome-checks"
    exit
fi
if [[ "${1:-}" == "quick-native-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/QuickBrowseNativeChecks.swift -o "$MANUAL/quick-native-checks"
    "$MANUAL/quick-native-checks"
    exit
fi
if [[ "${1:-}" == "quick-window-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/QuickBrowseWindowChecks.swift -o "$MANUAL/quick-window-checks"
    "$MANUAL/quick-window-checks"
    exit
fi
if [[ "${1:-}" == "quick-lifecycle-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/QuickBrowseLifecycleChecks.swift scripts/OwnedWebsiteStores.swift -o "$MANUAL/quick-lifecycle-checks"
    "$MANUAL/quick-lifecycle-checks"
    exit
fi
if [[ "${1:-}" == "quick-store-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/QuickBrowseStoreChecks.swift scripts/OwnedWebsiteStores.swift -o "$MANUAL/quick-store-checks"
    "$MANUAL/quick-store-checks"
    exit
fi
if [[ "${1:-}" == "quick-core-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" scripts/QuickBrowseCoreChecks.swift -o "$MANUAL/quick-core-checks"
    "$MANUAL/quick-core-checks"
    exit
fi
if [[ "${1:-}" == "website-test" || "${1:-}" == "quick-website-test" ]]; then run_website_checks "${1:-}"; exit; fi
if [[ "${1:-}" == "command-import-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/ProfileCommandImportChecks.swift -o "$MANUAL/profile-command-import-checks"
    "$MANUAL/profile-command-import-checks"
    exit
fi
if [[ "${1:-}" == "favorites-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/ProfileFavoriteChecks.swift -o "$MANUAL/profile-favorite-checks"
    "$MANUAL/profile-favorite-checks"
    exit
fi
if [[ "${1:-}" == "lifecycle-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/ProfileLifecycleChecks.swift -o "$MANUAL/profile-lifecycle-checks"
    "$MANUAL/profile-lifecycle-checks"
    exit
fi
if [[ "${1:-}" == "test" ]]; then
    run_extension_core_checks
    run_extension_download_checks
    run_extension_store_checks
    run_extension_runtime_checks
    run_extension_runtime_checks navigation
    run_extension_runtime_checks adapter
    run_extension_runtime_checks private
    run_extension_runtime_checks permission
    run_extension_runtime_checks action
    run_extension_runtime_checks command
    run_extension_runtime_checks reopen
    run_extension_runtime_checks surface
    run_extension_runtime_checks erasure
    run_sidebar_organization_checks
    run_sidebar_organization_layout_checks
    run_spaces_layout_checks
    run_space_checks
    run_writer_checks
    run_startup_checks
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/SiteSearchFixtures.swift scripts/BoostInputChecks.swift -o "$MANUAL/boosts-input-checks"
    "$MANUAL/boosts-input-checks"
    run_boosts_website_checks
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/SiteSearchFixtures.swift scripts/BoostStoreChecks.swift -o "$MANUAL/boosts-store-checks"
    "$MANUAL/boosts-store-checks"
    xcrun swiftc "${FLAGS[@]}" -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" scripts/BoostCoreChecks.swift -o "$MANUAL/boosts-core-checks"
    "$MANUAL/boosts-core-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/SiteSearchFixtures.swift scripts/LinkRoutingInputChecks.swift -o "$MANUAL/link-routing-input-checks"
    "$MANUAL/link-routing-input-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/SiteSearchFixtures.swift scripts/LinkRoutingStoreChecks.swift -o "$MANUAL/link-routing-store-checks"
    "$MANUAL/link-routing-store-checks"
    run_link_routing_website_checks
    xcrun swiftc "${FLAGS[@]}" -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" scripts/LinkRoutingCoreChecks.swift -o "$MANUAL/link-routing-core-checks"
    "$MANUAL/link-routing-core-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/SiteSearchFixtures.swift scripts/SiteSearchInputChecks.swift -o "$MANUAL/site-search-input-checks"
    "$MANUAL/site-search-input-checks"
    run_site_search_checks store
    run_site_search_checks website
    xcrun swiftc "${FLAGS[@]}" -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" scripts/SiteSearchCoreChecks.swift -o "$MANUAL/site-search-core-checks"
    "$MANUAL/site-search-core-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/PageOutputFixtures.swift scripts/PageOutputLifetimeChecks.swift -o "$MANUAL/page-output-lifetime-checks"
    "$MANUAL/page-output-lifetime-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/PageOutputFixtures.swift scripts/PageOutputChecks.swift -o "$MANUAL/page-output-checks"
    "$MANUAL/page-output-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/PageOutputWebsiteChecks.swift -o "$MANUAL/page-output-website-checks"
    "$MANUAL/page-output-website-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${SIDEBAR_SOURCES[@]}" scripts/SidebarInteractionChecks.swift -o "$MANUAL/sidebar-checks"
    "$MANUAL/sidebar-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/SidebarLayoutChecks.swift -o "$MANUAL/sidebar-layout-checks"
    "$MANUAL/sidebar-layout-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/ChromeChecks.swift -o "$MANUAL/chrome-checks"
    "$MANUAL/chrome-checks"
    xcrun swiftc "${FLAGS[@]}" -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" scripts/CoreChecks.swift -o "$MANUAL/checks"
    "$MANUAL/checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/StoreChecks.swift -o "$MANUAL/store-checks"
    "$MANUAL/store-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/ProfileStoreChecks.swift -o "$MANUAL/profile-store-checks"
    "$MANUAL/profile-store-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/QuickBrowseLifecycleChecks.swift scripts/OwnedWebsiteStores.swift -o "$MANUAL/quick-lifecycle-checks"
    "$MANUAL/quick-lifecycle-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/QuickBrowseStoreChecks.swift scripts/OwnedWebsiteStores.swift -o "$MANUAL/quick-store-checks"
    "$MANUAL/quick-store-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/QuickBrowseWindowChecks.swift -o "$MANUAL/quick-window-checks"
    "$MANUAL/quick-window-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/QuickBrowseNativeChecks.swift -o "$MANUAL/quick-native-checks"
    "$MANUAL/quick-native-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/ProfileCommandImportChecks.swift -o "$MANUAL/profile-command-import-checks"
    "$MANUAL/profile-command-import-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/ProfileFavoriteChecks.swift -o "$MANUAL/profile-favorite-checks"
    "$MANUAL/profile-favorite-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/ProfileLifecycleChecks.swift -o "$MANUAL/profile-lifecycle-checks"
    "$MANUAL/profile-lifecycle-checks"
    xcrun swiftc "${FLAGS[@]}" -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" scripts/QuickBrowseCoreChecks.swift -o "$MANUAL/quick-core-checks"
    "$MANUAL/quick-core-checks"
    xcrun swiftc "${FLAGS[@]}" -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" scripts/AppearanceChecks.swift -o "$MANUAL/appearance-checks"
    "$MANUAL/appearance-checks"
    xcrun swiftc "${FLAGS[@]}" -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" scripts/ProfileChecks.swift -o "$MANUAL/profile-checks"
    "$MANUAL/profile-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" Sources/Browser/UpdateController.swift scripts/UpdateChecks.swift -o "$MANUAL/update-checks"
    "$MANUAL/update-checks"
    run_website_checks
    exit
fi
xcrun swiftc "${FLAGS[@]}" -O -parse-as-library -whole-module-optimization -emit-object -module-name BrowserCore Sources/BrowserCore/*.swift -o "$MANUAL/BrowserCore.o"
xcrun swiftc "${FLAGS[@]}" -O -I "$MANUAL" Sources/Browser/*.swift "$MANUAL/BrowserCore.o" -o "$OUT/Contents/MacOS/Alcove"
mkdir -p "$OUT/Contents/Resources" .build/resources
if [[ ! -f .build/resources/Alcove.icns || scripts/Icon.swift -nt .build/resources/Alcove.icns ]]; then
    xcrun swiftc -sdk "$SDK" -module-cache-path "$PWD/.build/cache" -target "$(uname -m)-apple-macosx14.0" scripts/Icon.swift -o .build/resources/make-icon
    .build/resources/make-icon .build/resources/Alcove.iconset
fi
cp .build/resources/Alcove.icns "$OUT/Contents/Resources/Alcove.icns"
cp LICENSE "$OUT/Contents/Resources/LICENSE.txt"
cp scripts/Info.plist "$OUT/Contents/Info.plist"
if [[ -n "${BROWSER_BUNDLE_ID:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set CFBundleIdentifier $BROWSER_BUNDLE_ID" "$OUT/Contents/Info.plist"
fi
if [[ -n "${BROWSER_DISPLAY_NAME:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set CFBundleName $BROWSER_DISPLAY_NAME" "$OUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set CFBundleDisplayName $BROWSER_DISPLAY_NAME" "$OUT/Contents/Info.plist"
fi
codesign --force --sign - --options runtime --entitlements scripts/Entitlements.plist "$OUT"
printf 'Built %s/%s (%s, ad hoc signed, not notarized)\n' "$PWD" "$OUT" "$ARCH"
