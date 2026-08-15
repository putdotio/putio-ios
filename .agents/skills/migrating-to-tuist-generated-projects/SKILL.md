---
name: migrating-to-tuist-generated-projects
description: Migrates existing Xcode projects to Tuist generated workspaces with build and run validation, external dependency mapping, and migration checklists. Use when adopting Tuist for an existing app or converting a hand-edited Xcode project to generated projects.
---

# Migrating to Tuist Generated Projects

## Quick Start

1. Baseline build and run the app with xcodebuild.
2. Inventory targets, build settings, and external dependencies.
3. Create `Tuist.swift`, `Project.swift`, and `Tuist/Package.swift`.
4. Extract settings into `.xcconfig` files and wire them in `Project.swift`.
5. Generate and build: `tuist generate --no-open` then `xcodebuild build`.
6. Fix build issues, regenerate, and validate runtime on a simulator.

## Preflight Checklist

- Primary app scheme and any extension/test schemes
- Targets list (app, extensions, tests, helper tools)
- Deployment targets and bundle identifiers
- Info.plist locations and entitlements
- Custom build settings (per target and per configuration)
- External dependencies (SPM, XCFrameworks, local packages)
- Build scripts (SwiftGen, Sourcery, codegen)
- Runtime validation plan (simulator destination and launch command)

## Outputs

- `Project.swift` and `Tuist.swift`
- `Tuist/Package.swift` for external dependencies
- `.xcconfig` files (optional but recommended)
- Build and runtime validation notes
- A short migration log of decisions and fixes

## Migration Workflow

### 1. Baseline the project

Start by proving the current project builds and runs. Capture the command you use so the generated workspace can be validated the same way.

```bash
xcodebuild build \
  -project App.xcodeproj \
  -scheme App \
  -configuration Debug \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath DerivedDataBaseline
```

### 2. Map targets and settings

List every target and its role. Extract build settings into `.xcconfig` files when they are large or shared across targets. Keep deployment targets and bundle identifiers identical to the original project to avoid runtime surprises.

### 3. Add Tuist manifests

Create the manifests and keep them minimal and close to the existing project.

- `Tuist.swift`: enable generation options you need and keep them explicit.
- `Project.swift`: define targets, sources, resources, scripts, and dependencies.
- `Tuist/Package.swift`: list external dependencies and map product types.

Use `.external` for third-party dependencies to keep the graph consistent.

### 4. Handle sources and resources carefully

Be precise here. Small mistakes often cause large failures later.

- `.intentdefinition` files belong in `sources`, not `resources`.
- `.xcstrings` should remain the primary localization source. Avoid double-including `.strings` or `.stringsdict` from overlapping globs.
- Use `.folderReference` for bundles like `Settings.bundle`.
- If a resource bundle is missing, ensure the package target declares `.process("Resources")`.

### 5. Generate and build

```bash
tuist install
tuist generate --no-open
xcodebuild build \
  -workspace App.xcworkspace \
  -scheme App \
  -configuration Debug \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath DerivedDataTuist
```

### 6. Resolve build issues iteratively

Common fixes you will likely need:

- **Missing SDK frameworks**: add `.sdk(name: ..., type: .framework)`.
- **SPM resource bundles**: verify `.process("Resources")` and `Bundle.module` usage.
- **File-system-synchronized groups**: avoid over-excluding directories; compare with the pbx if a type vanishes.
- **Invalid bundle identifiers**: override with `PackageSettings` or vendor a local package.
- **Generated sources**: ensure codegen outputs (SwiftGen/Sourcery) are part of the build.

### 7. Validate runtime

A build is not enough; launch the app on a simulator.

Before booting, snapshot the matching devices and their states. Create or select one exact device,
record its UDID, and decide whether this validation attempt owns it. Register cleanup before the
first later failure point. On success, failure, timeout, or cancellation, shut down and delete only
a device created by this attempt; preserve every preexisting device and keep the validation failure
as the command's exit status if cleanup also fails. Persistent preview sessions must print the exact
UDID and an explicit teardown command instead of silently leaving the device running.

```bash
set -euo pipefail
device_name="tuist-validation-$(uuidgen | tr '[:upper:]' '[:lower:]')"
preexisting_ids="$(xcrun simctl list devices -j | jq -r --arg name "$device_name" \
  '.devices[][] | select(.name == $name) | .udid' | sort)"
owned_ids=""
reconciliation_pending=0
uuid_pattern='^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$'
add_owned_ids() {
  local candidates="$1" identifier
  while IFS= read -r identifier; do
    if [[ "$identifier" =~ $uuid_pattern ]]; then
      owned_ids="$(printf '%s\n%s\n' "$owned_ids" "$identifier" | sed '/^$/d' | sort -u)"
    fi
  done <<< "$candidates"
}
reconcile_device_ids() {
  local current_ids
  if ! current_ids="$(xcrun simctl list devices -j | jq -r --arg name "$device_name" \
    '.devices[][] | select(.name == $name) | .udid' | sort)"; then
    return 1
  fi
  comm -13 <(printf '%s\n' "$preexisting_ids") <(printf '%s\n' "$current_ids")
}
cleanup() {
  primary_status=$?
  cleanup_failed=0
  trap '' INT TERM
  trap - EXIT
  if [[ "$reconciliation_pending" -eq 1 || -z "$owned_ids" ]]; then
    if reconciled_ids="$(reconcile_device_ids)"; then
      add_owned_ids "$reconciled_ids"
      if [[ -z "$reconciled_ids" ]]; then
        printf 'warning: unresolved owned Simulator %s requires manual reconciliation\n' \
          "$device_name" >&2
        cleanup_failed=1
      fi
    else
      printf 'warning: failed to reconcile owned Simulator %s during teardown\n' \
        "$device_name" >&2
      cleanup_failed=1
    fi
  fi
  while IFS= read -r owned_id; do
    [[ -z "$owned_id" ]] && continue
    if ! xcrun simctl shutdown "$owned_id" >/dev/null 2>&1; then
      printf 'warning: failed to shut down owned Simulator %s\n' "$owned_id" >&2
      cleanup_failed=1
    fi
    if ! xcrun simctl delete "$owned_id" >/dev/null 2>&1; then
      printf 'warning: failed to delete owned Simulator %s\n' "$owned_id" >&2
      cleanup_failed=1
    fi
    if ! xcrun simctl list devices -j | jq -e --arg id "$owned_id" \
      '[.devices[][] | select(.udid == $id)] | length == 0' >/dev/null; then
      printf 'warning: owned Simulator %s remains after teardown or absence verification failed\n' \
        "$owned_id" >&2
      cleanup_failed=1
    fi
  done <<< "$owned_ids"
  if [[ "$cleanup_failed" -ne 0 ]]; then
    printf 'warning: Simulator teardown failed; preserving primary exit status %s\n' \
      "$primary_status" >&2
  fi
  exit "$primary_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
set +e
created_output="$(xcrun simctl create "$device_name" \
  "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" \
  "com.apple.CoreSimulator.SimRuntime.iOS-26-0")"
create_status=$?
set -e
add_owned_ids "$created_output"
if [[ "$create_status" -ne 0 ]]; then
  if reconciled_ids="$(reconcile_device_ids)"; then
    add_owned_ids "$reconciled_ids"
  else
    reconciled_ids=""
  fi
  if [[ -z "$reconciled_ids" ]]; then
    reconciliation_pending=1
  fi
  exit "$create_status"
fi
if [[ -z "$owned_ids" ]]; then
  printf 'create returned no valid Simulator UDID\n' >&2
  exit 1
fi
device_id="$(printf '%s\n' "$owned_ids" | head -n 1)"
xcrun simctl boot "$device_id"
xcrun simctl install "$device_id" DerivedDataTuist/Build/Products/Debug-iphonesimulator/App.app
xcrun simctl launch "$device_id" com.example.app
```

## Common Failure Patterns

- **Type not found**: a source file or entire directory was excluded accidentally.
- **Copy Bundle Resources errors**: Swift files are being treated as resources; fix the resource globs.
- **Localization conflicts**: `.xcstrings` colliding with `.strings` globs.
- **Undefined symbols**: missing SDK frameworks or dependency products.
- **Unrecognized selector at launch**: ObjC categories in static frameworks were stripped. Add `-ObjC` to `OTHER_LDFLAGS` or `-force_load` for the library that defines the category.
- **Runtime crash on launch**: mismatched bundle id, missing entitlements, or miswired resources.

## Migration Notes to Capture

- What changed in `Project.swift` and why
- Any exclusions or overrides (and the reason)
- Dependency patches or local vendoring
- The exact build and run commands used for validation

## Done Checklist

- Generated workspace builds cleanly
- App launches on simulator without immediate crash
- All targets and extensions build
- Dependencies are wired through `.external`
- Settings match the original Xcode project
