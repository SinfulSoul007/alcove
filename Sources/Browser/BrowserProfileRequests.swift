import AppKit
import BrowserCore

@MainActor
extension BrowserStore {
    var canModifyLocalMetadata: Bool { isPrivate || savingEnabled }
    var canManageProfiles: Bool { !isPrivate && savingEnabled && !profileDataOperationInProgress && !isShuttingDown }

    func requestCreateProfile() {
        guard profileManagementReady() else { return }
        guard let name = profileNamePrompt(title: "Create a Profile", detail: "A profile keeps its own website logins, Favorites, bookmarks and history. A new Space will open for it.", value: "", action: "Create") else { return }
        guard profileManagementReady() else { return }
        do { _ = try createProfile(name: name) }
        catch { message = error.localizedDescription }
    }

    func requestRenameProfile(_ id: UUID) {
        guard profileManagementReady(), let profile = availableProfileForRequest(id) else { return }
        guard let name = profileNamePrompt(title: "Rename Profile", detail: "Choose a name for \(profile.name).", value: profile.name, action: "Rename") else { return }
        guard profileManagementReady(), availableProfileForRequest(id) != nil else { return }
        do { try renameProfile(id, name: name) }
        catch { message = error.localizedDescription }
    }

    func requestNewSpace(profileID: UUID? = nil) {
        let id = profileID ?? activeProfileID
        guard !isShuttingDown, canModifyLocalMetadata, !profileDataOperationInProgress else { return }
        if !isPrivate { guard availableProfileForRequest(id) != nil else { return } }
        let detail = isPrivate ? "Give this temporary collection of private tabs a name." : "This Space will use the \(profiles.first(where: { $0.id == id })?.name ?? "selected") profile’s logins and library."
        guard let name = profileNamePrompt(title: "Create a Space", detail: detail, value: "", action: "Create") else { return }
        guard !isShuttingDown, canModifyLocalMetadata, !profileDataOperationInProgress else { return }
        if !isPrivate { guard availableProfileForRequest(id) != nil else { return } }
        var newSpace = Space(name: name); newSpace.profileID = id
        if isPrivate { session.spaces.append(newSpace); selectSpace(newSpace.id) }
        else {
            var candidate = makeDocument(); candidate.session.spaces.append(newSpace); candidate.session.selectedSpace = newSpace.id
            do { try commitProfileDocument(candidate); closePeek(); splitID = nil; activePaneID = nil }
            catch { message = error.localizedDescription }
        }
    }

    func requestAssignProfile(_ id: UUID, to spaceID: UUID) {
        guard profileManagementReady(), let profile = availableProfileForRequest(id),
              let source = session.spaces.first(where: { $0.id == spaceID }), source.effectiveProfileID != id,
              availableProfileForRequest(source.effectiveProfileID) != nil else { return }
        let previousID = source.effectiveProfileID
        guard profileConfirmation(title: "Use \(profile.name) for \(source.name)?", detail: "Pages in this Space will reload with \(profile.name)’s website logins. Unsaved forms and page state will be lost. Tab URLs and pins stay in this Space; Favorites and the Library follow the selected profile. Cookies are never transferred.", action: "Reload and Change Profile") else { return }
        guard profileManagementReady(), availableProfileForRequest(id) != nil,
              availableProfileForRequest(previousID) != nil,
              session.spaces.first(where: { $0.id == spaceID })?.effectiveProfileID == previousID else { return }
        do { try assignProfile(id, to: spaceID) }
        catch { message = error.localizedDescription }
    }

    func requestDeleteProfile(_ id: UUID) {
        guard profileManagementReady(), let profile = profiles.first(where: { $0.id == id }),
              !profile.isDefault, !profile.isPendingClear, profile.isPendingDeletion || !profileUnavailable(id),
              !session.spaces.contains(where: { $0.effectiveProfileID == id }) else { return }
        let title = profile.isPendingDeletion ? "Finish deleting \(profile.name)?" : "Delete \(profile.name)?"
        guard profileConfirmation(title: title, detail: "Permanently remove this profile’s website logins, bookmarks, Favorites and history. Other profiles and downloaded files are kept. This cannot be undone.", action: profile.isPendingDeletion ? "Retry Deletion" : "Delete Profile", destructive: true) else { return }
        guard profileManagementReady(), let current = profiles.first(where: { $0.id == id }),
              !current.isDefault, !current.isPendingClear, current.isPendingDeletion || !profileUnavailable(id),
              !session.spaces.contains(where: { $0.effectiveProfileID == id }) else { return }
        Task { do { try await deleteProfile(id) } catch { message = error.localizedDescription } }
    }

    func requestClearProfileData(_ id: UUID) {
        guard !isShuttingDown, canModifyLocalMetadata, !profileDataOperationInProgress else { return }
        let pending: Bool
        let name: String
        if isPrivate { guard id == BrowserProfile.defaultID else { return }; pending = false; name = "this private window" }
        else {
            guard let profile = profiles.first(where: { $0.id == id }), !profile.isPendingDeletion,
                  profile.isPendingClear || !profileUnavailable(id) else { return }
            pending = profile.isPendingClear; name = "the \(profile.name) profile"
        }
        let detail = pending
            ? "Finish the website-data clear already started for \(name). Links queued after its initial reset, bookmarks, downloaded files and other profiles are kept."
            : "This signs you out and closes all tabs, pins and Favorites in \(name). Its history, archive and recently closed tabs are cleared. Bookmarks, downloaded files and other profiles are kept."
        guard profileConfirmation(title: pending ? "Finish clearing website data?" : "Clear website data and history?", detail: detail, action: pending ? "Retry Clear" : "Clear Data", destructive: true) else { return }
        guard !isShuttingDown, canModifyLocalMetadata, !profileDataOperationInProgress else { return }
        if !isPrivate {
            guard let current = profiles.first(where: { $0.id == id }), !current.isPendingDeletion,
                  current.isPendingClear == pending, pending || !profileUnavailable(id) else { return }
        }
        Task { do { try await clearProfileData(id) } catch { message = error.localizedDescription } }
    }

    @discardableResult
    func requestMoveTab(_ id: UUID, to destination: UUID) -> Bool {
        guard let tab = tab(id) else { return false }
        return requestPlaceTab(id, in: destination, section: tab.favorite == true ? .favorites : (tab.pinned ? .pinned : .today), folder: tab.folder)
    }

    @discardableResult
    func requestPlaceTab(_ id: UUID, in destination: UUID, section: SidebarSection, before target: UUID? = nil, folder: String? = nil) -> Bool {
        guard canModifyLocalMetadata, !profileDataOperationInProgress, !isShuttingDown,
              let sourceProfileID = profileID(for: id), tab(id) != nil,
              let dest = session.spaces.first(where: { $0.id == destination }) else { return false }
        let sourceSpaceID = session.spaces.first(where: { $0.tabs.contains(where: { $0.id == id }) })?.id
        let destinationProfileID = dest.effectiveProfileID
        let changingProfile = !isPrivate && sourceProfileID != destinationProfileID
        if !isPrivate {
            guard availableProfileForRequest(sourceProfileID) != nil,
                  let profile = availableProfileForRequest(destinationProfileID) else { return false }
            if changingProfile {
                guard profileConfirmation(title: "Move tab to \(dest.name)?", detail: "This page will reload with the \(profile.name) profile’s website logins. Unsaved forms and page state will be lost. Cookies are never transferred.", action: "Reload and Move") else { return false }
            }
        }
        // A modal can process other events. Consent applies only to the original owners.
        guard canModifyLocalMetadata, !profileDataOperationInProgress, !isShuttingDown,
              session.spaces.first(where: { $0.tabs.contains(where: { $0.id == id }) })?.id == sourceSpaceID,
              profileID(for: id) == sourceProfileID, tab(id) != nil,
              session.spaces.first(where: { $0.id == destination })?.effectiveProfileID == destinationProfileID else { return false }
        if !isPrivate { guard availableProfileForRequest(sourceProfileID) != nil, availableProfileForRequest(destinationProfileID) != nil else { return false } }
        return placeTab(id, in: destination, section: section, before: target, folder: folder, allowProfileChange: changingProfile)
    }

    private func profileManagementReady() -> Bool {
        guard !isPrivate else { message = ProfileError.privateMode.localizedDescription; return false }
        guard savingEnabled else { message = ProfileError.locked.localizedDescription; return false }
        guard !profileDataOperationInProgress, !isShuttingDown else { return false }
        return true
    }

    private func availableProfileForRequest(_ id: UUID) -> BrowserProfile? {
        guard !isPrivate, let profile = profiles.first(where: { $0.id == id }), !profileUnavailable(id) else { return nil }
        return profile
    }

    private func profileNamePrompt(title: String, detail: String, value: String, action: String) -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        let field = NSTextField(string: value); field.placeholderString = "Name"; field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: action); alert.addButton(withTitle: "Cancel"); alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        return name.isEmpty ? nil : name
    }

    private func profileConfirmation(title: String, detail: String, action: String, destructive: Bool = false) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.alertStyle = .warning
        alert.addButton(withTitle: action); alert.addButton(withTitle: "Cancel")
        if destructive { alert.buttons.first?.hasDestructiveAction = true }
        return alert.runModal() == .alertFirstButtonReturn
    }
}
