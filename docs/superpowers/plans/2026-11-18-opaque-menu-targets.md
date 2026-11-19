# Opaque Menu Targets Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for this task.

**Goal:** Support unchanged full uBO subscription menus without changing website access.

**Architecture:** Native menu-only validation and matching; separate opaque target state alongside structured patterns. Existing host/document parsing remains untouched.

**Tech Stack:** Swift native probe, C++, pinned WebKit, macOS VM.

**Spec:** `docs/superpowers/specs/2026-11-18-opaque-menu-targets-design.md`

## Global Constraints

- Upstream pin26695efdefc6076049ec50713a2c4e54b90b4d47; preserve all11 existing patches.
- macOS browser floor14, native extensions15.4. No extension package modification or JS menu shim.
- Research only until actual changed-engine runtime tests pass; no public DMG replacement.

## Review Focus

- Exact mixed structured/opaque uBO target arrays behave as OR filters.
- Target updates clear both representations; removeAll never leaves a stale item.
- Special schemes, malformed opaque patterns and opaque document/host patterns remain denied.
- Literal query delimiters, fragments and scheme matching are handled without invoking a URI.
- No global scheme registration or host/content-script permission expansion.

### Task 1: Native opaque target menus

**Files:** native WebExtensionMatchPattern.cpp/.h, WebExtensionMenuItem.cpp/.h, Cocoa/WebExtensionMenuItemCocoa.mm and WebProcess API/Cocoa/WebExtensionAPIMenusCocoa.mm; research diagnostics/webkit-menu-targets.patch, diagnostics/webkit-menu-targets-probe.swift, diagnostics/verify-probe-environment.py and .github/workflows/build-webkit.yml.

**Interfaces:** menu-specific `isValidOpaqueMenuTargetPattern(const String&)` and `opaqueMenuTargetPatternMatchesURL(const String&,const URL&)`; private opaque target vector on WebExtensionMenuItem.

- [x] Add owned native extension create/update probe, including exact uBO mixed targets, ordinary controls and unchanged grants.
- [x] Run on stock VM; expect rejection specifically for abp:* while structured controls work. Prove actual menu inspection works on the structured control before using it for the changed engine.
- [x] Add only native menu-specific validation/storage/matching. Preserve general match-pattern parsing.
- [ ] Apply all12 patches to fresh pinned sources, verify resulting bytes, and type-check probe warning-clean. Review whole branch and fix material findings with regressions.
- [ ] Push research branch and track actual engine compile/native checks. Native positive is a completion gate, not inferred from source checks.
