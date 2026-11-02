import XCTest
@testable import ZacroCore

@MainActor final class ElectronParityTests: XCTestCase {
  private func directory() throws -> URL {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("zacro-parity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: path) }
    return path
  }
  private func store() throws -> BrowserStore { BrowserStore(directory: try directory()) }
  private func tab(_ store: BrowserStore, _ name: String) throws -> BrowserTab {
    try XCTUnwrap(store.createTab(address: "https://example.com/" + name))
  }

  func testExtensionTabMetadataDefaultsPersistAndRemapAcrossPortableImport() throws {
    let root = try directory(), s = BrowserStore(directory:root)
    let opener = try tab(s,"opener"), child = try tab(s,"child")
    let legacy = try JSONDecoder().decode(BrowserTab.self,from:JSONEncoder().encode(child))
    XCTAssertNil(legacy.autoDiscardable); XCTAssertTrue(legacy.autoDiscardable != false); XCTAssertNil(legacy.openerTabID)
    try s.commit { state in
      let index = state.tabs.firstIndex { $0.id == child.id }!
      state.tabs[index].autoDiscardable = false; state.tabs[index].openerTabID = opener.id
    }
    let reopened = BrowserStore(directory:root)
    XCTAssertEqual(reopened.tab(child.id)?.autoDiscardable,false)
    XCTAssertEqual(reopened.tab(child.id)?.openerTabID,opener.id)
    let exported = root.appendingPathComponent("portable.json"); try reopened.exportData(to:exported)
    let imported = try store(); try imported.importData(from:exported)
    let importedChild = try XCTUnwrap(imported.state.tabs.first { $0.url == child.url })
    let importedOpener = try XCTUnwrap(imported.state.tabs.first { $0.url == opener.url })
    XCTAssertEqual(importedChild.autoDiscardable,false)
    XCTAssertEqual(importedChild.openerTabID,importedOpener.id)
    XCTAssertNotEqual(importedChild.openerTabID,opener.id)
  }

  func testOpenerRepairRejectsOtherProfilesSelfMissingAndClosedTabs() throws {
    let s = try store(), opener = try tab(s,"opener"), child = try tab(s,"child")
    let home = s.state.activeSpaceID
    _ = s.createProfile(name:"Other"); let foreign = try tab(s,"foreign")
    s.selectSpace(id:home)
    for invalid in [child.id,foreign.id,"missing"] {
      s.updateTab(child.id) { $0.openerTabID = invalid }; s.repair()
      XCTAssertNil(s.tab(child.id)?.openerTabID)
    }
    s.togglePin(id:opener.id)
    s.updateTab(child.id) { $0.openerTabID = opener.id }; s.repair()
    XCTAssertEqual(s.tab(child.id)?.openerTabID,opener.id)
    s.closeTab(id:opener.id)
    XCTAssertNil(s.tab(child.id)?.openerTabID)
    s.updateTab(child.id) { $0.openerTabID = opener.id }; s.repair()
    XCTAssertNil(s.tab(child.id)?.openerTabID)
    s.selectTab(id:opener.id); s.updateTab(child.id) { $0.openerTabID = opener.id }
    s.closeTab(id:child.id)
    XCTAssertNil(s.state.archive.first { $0.id == child.id }?.tab.openerTabID)
  }

  func testSplitSelectionWakesClosedPinsWithoutWakingInvalidCandidates() throws {
    let s = try store(), left = try tab(s,"left"), pin = try tab(s,"pin")
    s.togglePin(id:pin.id); s.closeTab(id:pin.id); s.selectTab(id:left.id)
    s.setSplit(left:left.id,right:pin.id)
    XCTAssertEqual(s.tab(pin.id)?.isClosed,false)
    XCTAssertEqual(s.split(for:left.id)?.rightTabID,pin.id)
    XCTAssertEqual(s.state.activeTabID,left.id)
    let reopened = BrowserStore(directory:s.directory)
    XCTAssertEqual(reopened.tab(pin.id)?.isClosed,false); XCTAssertNotNil(reopened.split(for:left.id))
    s.unsplit(tabID:left.id)
    let ordinary = try tab(s,"ordinary"); s.updateTab(ordinary.id) { $0.isClosed = true }; s.selectTab(id:left.id)
    s.setSplit(left:left.id,right:ordinary.id)
    XCTAssertNil(s.split(for:left.id)); XCTAssertEqual(s.tab(ordinary.id)?.isClosed,true)
  }

  func testSharedFavoriteOnlyRefreshesSplitPartnerWhenItsOriginalSpaceIsVisible() throws {
    let s = try store(), left = try tab(s, "left"), right = try tab(s, "right")
    s.toggleFavorite(id: left.id)
    s.setSplit(left: left.id, right: right.id)
    let original = s.state.activeSpaceID
    _ = s.createSpace(name: "Other")
    s.selectTab(id: left.id)
    let old = Date(timeIntervalSince1970: 100), now = Date(timeIntervalSince1970: 500)
    s.updateTab(left.id) { $0.lastAccessedAt = old }; s.updateTab(right.id) { $0.lastAccessedAt = old }
    s.recordVisibleTabActivity(now: now)
    XCTAssertEqual(s.tab(left.id)?.lastAccessedAt, now)
    XCTAssertEqual(s.tab(right.id)?.lastAccessedAt, old)
    s.selectSpace(id: original); s.selectTab(id: left.id)
    s.recordVisibleTabActivity(now: now)
    XCTAssertEqual(s.tab(right.id)?.lastAccessedAt, now)
  }

  func testDurableCreationCommitsWholeProfileAndFolderOrKeepsPriorState() throws {
    let root = try directory(), s = BrowserStore(directory: root)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("native-state.json"), withIntermediateDirectories: true)
    let before = s.state
    XCTAssertThrowsError(try s.createProfileDurably(name: "Must stay draft"))
    XCTAssertEqual(s.state, before)
    XCTAssertThrowsError(try s.createFolderDurably(name: "Must stay draft"))
    XCTAssertEqual(s.state, before)
    try FileManager.default.removeItem(at: root.appendingPathComponent("native-state.json"))
    let profile = try s.createProfileDurably(name: "Work")
    XCTAssertEqual(s.state.activeProfile?.id, profile.id)
    XCTAssertEqual(s.state.activeSpace?.name, "Work")
    let folder = try s.createFolderDurably(name: "Research")
    XCTAssertEqual(BrowserStore(directory: root).state.folders.first?.id, folder.id)
    XCTAssertThrowsError(try s.createFolderDurably(name: "Child", parentID: "missing"))
    let secret = try s.createProfileDurably(name: "Private", isPrivate: true)
    XCTAssertEqual(s.state.activeProfile?.id, secret.id)
    XCTAssertEqual(s.state.activeSpace?.icon, "moon")
    XCTAssertEqual(s.state.activeSpace?.theme.primaryColor, "#69519c")
    XCTAssertFalse(BrowserStore(directory: root).state.profiles.contains { $0.id == secret.id })
  }

  func testBookmarkDatesSurviveLegacyNativeAndPortableRoundTrips() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let old = Data(#"{"id":"old","profileID":"default","url":"https://example.com/","title":"Old"}"#.utf8)
    XCTAssertEqual(try JSONDecoder().decode(Bookmark.self, from: old).createdAt, .distantPast)
    let s = try store()
    s.toggleBookmark(url: "https://example.com/", title: "Example")
    XCTAssertGreaterThan(s.state.bookmarks[0].createdAt, Date().addingTimeInterval(-5))
    s.state.bookmarks[0].createdAt = date
    try s.flush()
    XCTAssertEqual(BrowserStore(directory: s.directory).state.bookmarks[0].createdAt, date)
    let export = s.directory.appendingPathComponent("export.json")
    try s.exportData(to: export)
    let imported = try store(); try imported.importData(from: export)
    XCTAssertEqual(imported.state.bookmarks.first?.createdAt, date)
  }
  func testPrivateProfileDiscardDoesNotDependOnWritablePublicStore() throws {
    let root = try directory(), s = BrowserStore(directory: root)
    let secret = try s.createProfileDurably(name: "Private", isPrivate: true)
    let tab = try tab(s, "private")
    s.toggleBookmark(url: tab.url, title: "Secret")
    s.setPermission(profileID: secret.id, origin: tab.url, permission: "camera", allowed: true)
    let oldState = try Data(contentsOf: root.appendingPathComponent("native-state.json"))
    try FileManager.default.removeItem(at: root.appendingPathComponent("native-state.json"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("native-state.json"), withIntermediateDirectories: true)
    s.discardPrivateProfile(id: secret.id)
    XCTAssertFalse(s.state.profiles.contains { $0.id == secret.id })
    XCTAssertFalse(s.state.tabs.contains { $0.id == tab.id })
    XCTAssertTrue(s.state.bookmarks.isEmpty); XCTAssertTrue(s.state.permissions.isEmpty)
    XCTAssertEqual(s.state.activeProfile?.isPrivate, false)
    XCTAssertNotNil(s.state.activeSpace)
    XCTAssertEqual(s.lastError, nil)
    let before = s.state
    s.discardPrivateProfile(id: s.activeProfileID)
    XCTAssertEqual(s.state, before)
    XCTAssertFalse(String(decoding: oldState, as: UTF8.self).contains("Secret"))
  }
  func testShortcutAndSearchEditorsKeepDraftStateWhenPersistenceFails() throws {
    let root = try directory(), s = BrowserStore(directory: root)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("native-state.json"), withIntermediateDirectories: true)
    let before = s.state
    XCTAssertThrowsError(try s.setSiteSearches([.init(name: "Docs", keyword: "docs", url: "https://example.com/search?q=%s")]))
    XCTAssertEqual(s.state, before)
    XCTAssertThrowsError(try s.updateShortcut(id: "new-tab", accelerator: "Mod+Shift+K"))
    XCTAssertEqual(s.state, before)
    XCTAssertThrowsError(try s.resetShortcut())
    XCTAssertEqual(s.state, before)
  }

  func testFolderDragCapturesStablePinAndUnpinReopensClosedPage() throws {
    let s = try store(), a = try tab(s,"start")
    let folder = s.createFolder(name:"Research")
    s.moveTab(id:a.id,folderID:folder.id)
    s.navigate(tabID:a.id,address:"https://example.com/away",title:"Away")
    s.closeTab(id:a.id)
    XCTAssertEqual(s.tab(a.id)?.url,a.url)
    XCTAssertEqual(s.tab(a.id)?.displayTitle,a.title)
    s.moveTab(id:a.id,pinned:false)
    XCTAssertEqual(s.tab(a.id)?.isClosed,false)
    XCTAssertNil(s.tab(a.id)?.folderID)
    XCTAssertNil(s.tab(a.id)?.savedURL)
  }
  func testReorderKeepsFolderButExplicitDropRemovesIt() throws {
    let s = try store(), a = try tab(s,"a")
    let folder = s.createFolder(name:"Reading")
    s.moveTab(id:a.id,folderID:folder.id)
    s.moveTab(id:a.id,index:0)
    XCTAssertEqual(s.tab(a.id)?.folderID,folder.id)
    s.moveTab(id:a.id,pinned:true,favorite:false,clearFolder:true)
    XCTAssertNil(s.tab(a.id)?.folderID)
    XCTAssertEqual(s.tab(a.id)?.savedURL,a.url)
  }
  func testFavoriteUnpinUsesCurrentSpaceAndUnfavoriteRemainsPinned() throws {
    let s = try store(), a = try tab(s,"a")
    s.toggleFavorite(id:a.id)
    let work = s.createSpace(name:"Work")
    XCTAssertNil(s.state.activeTabID)
    s.toggleFavorite(id:a.id)
    XCTAssertEqual(s.tab(a.id)?.spaceID,work.id)
    XCTAssertEqual(s.tab(a.id)?.isPinned,true)
    XCTAssertEqual(s.tab(a.id)?.isFavorite,false)
    s.toggleFavorite(id:a.id)
    s.selectSpace(id:"home")
    s.togglePin(id:a.id)
    XCTAssertEqual(s.tab(a.id)?.spaceID,"home")
    XCTAssertEqual(s.tab(a.id)?.isPinned,false)
  }
  func testRememberedFavoriteRetainsIdentityAcrossSpaces() throws {
    let s = try store(), favorite = try tab(s,"favorite")
    s.toggleFavorite(id:favorite.id)
    let work = s.createSpace(name:"Work")
    s.selectTab(id:favorite.id)
    s.selectSpace(id:"home")
    XCTAssertEqual(s.state.activeTabID,favorite.id)
    XCTAssertEqual(s.tab(favorite.id)?.spaceID,"home")
    s.selectSpace(id:work.id)
    XCTAssertEqual(s.tab(favorite.id)?.spaceID,work.id)
    XCTAssertEqual(s.state.tabs.count,1)
  }
  func testSpaceCannotRememberForeignProfileTab() throws {
    let s = try store(), personal = try tab(s,"personal")
    _ = s.createProfile(name:"Work")
    s.updateSpace(s.state.activeSpaceID) { $0.lastActiveTabID = personal.id }
    s.selectSpace(id:s.state.activeSpaceID)
    XCTAssertNil(s.state.activeTabID)
  }
  func testMovingInactiveSplitMemberMovesActivePartnerAndOnlySourceClassification() throws {
    let s = try store(), a = try tab(s,"a"), b = try tab(s,"b")
    s.toggleFavorite(id:a.id); s.setSplit(left:a.id,right:b.id)
    let destination = s.createSpace(name:"Work")
    s.selectTab(id:b.id)
    s.moveTab(id:a.id,spaceID:destination.id,pinned:true,favorite:false)
    XCTAssertEqual(s.state.activeTabID,b.id)
    XCTAssertEqual(s.state.activeSpaceID,destination.id)
    XCTAssertEqual(s.tab(b.id)?.spaceID,destination.id)
    XCTAssertEqual(s.tab(b.id)?.isPinned,false)
    XCTAssertEqual(s.tab(a.id)?.isFavorite,false)
    XCTAssertEqual(s.split(for:b.id)?.spaceID,destination.id)
  }
  func testSharedFavoriteLeavingSplitSpaceDoesNotDestroySavedSplit() throws {
    let s = try store(), a = try tab(s,"a"), b = try tab(s,"b")
    s.toggleFavorite(id:a.id); s.setSplit(left:a.id,right:b.id)
    _ = s.createSpace(name:"Work"); s.selectTab(id:a.id); s.repair()
    XCTAssertNotNil(s.split(for:a.id))
    s.selectSpace(id:"home"); s.selectTab(id:b.id)
    XCTAssertEqual(s.split(for:b.id)?.leftTabID,a.id)
  }
  func testSpaceDeletionMovesOpenArchivedAndSplitTabs() throws {
    let s = try store()
    let work = s.createSpace(name:"Work"), a = try tab(s,"a"), b = try tab(s,"b"), c = try tab(s,"c")
    let folder = s.createFolder(name:"Folder")
    s.moveTab(id:a.id,folderID:folder.id)
    s.setSplit(left:a.id,right:b.id)
    s.closeTab(id:c.id); s.deleteSpace(id:work.id)
    XCTAssertEqual(s.tab(a.id)?.spaceID,"home")
    XCTAssertEqual(s.tab(b.id)?.spaceID,"home")
    XCTAssertEqual(s.state.archive.first?.tab.spaceID,"home")
    XCTAssertEqual(s.split(for:a.id)?.spaceID,"home")
    XCTAssertNil(s.tab(a.id)?.folderID)
    XCTAssertTrue(s.state.folders.isEmpty)
  }
  func testClosingPinChoosesNextOrdinaryTabAndNeverActivatesAnotherPin() throws {
    let s = try store(), a = try tab(s,"a"), b = try tab(s,"b"), c = try tab(s,"c")
    s.togglePin(id:a.id); s.togglePin(id:b.id); s.selectTab(id:a.id); s.closeTab(id:a.id)
    XCTAssertEqual(s.state.activeTabID,c.id)
    s.closeTab(id:c.id)
    XCTAssertNil(s.state.activeTabID)
  }
  func testClearHistoryPreservesArchiveButPurgesRecoveryHistories() throws {
    let s = try store(), a = try tab(s,"a")
    s.navigate(tabID:a.id,address:"https://example.com/visited-secret")
    s.navigate(tabID:a.id,address:"https://example.com/current")
    s.closeTab(id:a.id)
    s.clearHistory()
    XCTAssertEqual(s.state.archive.count,1)
    XCTAssertEqual(s.state.archive[0].tab.navigation.map(\.url),["https://example.com/current"])
    for name in ["native-state.json","native-state.json.bak"] {
      let text = try String(contentsOf:s.directory.appendingPathComponent(name),encoding:.utf8)
      XCTAssertFalse(text.contains("visited-secret"))
    }
  }
  func testCorruptPrimaryRecoversBackupAndPreservesEvidence() throws {
    let s = try store(), a = try tab(s,"a")
    s.save()
    try Data("bad primary".utf8).write(to:s.directory.appendingPathComponent("native-state.json"))
    let recovered = BrowserStore(directory:s.directory)
    XCTAssertEqual(recovered.tab(a.id)?.url,a.url)
    XCTAssertNotNil(recovered.lastError)
    recovered.save()
    let originals = try FileManager.default.contentsOfDirectory(at:s.directory,includingPropertiesForKeys:nil).filter { $0.lastPathComponent.hasPrefix("native-state-unreadable-") }
    XCTAssertEqual(originals.count,1)
    XCTAssertEqual(try String(contentsOf:originals[0],encoding:.utf8),"bad primary")
    let permissions = try FileManager.default.attributesOfItem(atPath:s.directory.appendingPathComponent("native-state.json").path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue,0o600)
  }
  func testRepairPreservesCurrentNavigationIndexWhileRemovingUnsafeEntries() throws {
    let s = try store(), a = try tab(s,"current")
    s.updateTab(a.id) { tab in
      tab.navigation = [.init(url:"file:///secret"),.init(url:"https://example.com/before"),.init(url:a.url),.init(url:"https://example.com/after"),.init(url:"https://user:pass@example.com/")]
      tab.navigationIndex = 2
    }
    s.repair()
    XCTAssertEqual(s.tab(a.id)?.navigationIndex,1)
    XCTAssertEqual(s.back(tabID:a.id),"https://example.com/before")
    XCTAssertEqual(s.forward(tabID:a.id),a.url)
    XCTAssertEqual(s.forward(tabID:a.id),"https://example.com/after")
  }
  func testLongNavigationKeepsBothSidesOfCurrentPageAndNoOpaqueState() throws {
    let s = try store(), a = try tab(s,"250")
    s.updateTab(a.id) { tab in tab.navigation = (0..<500).map { .init(url:"https://example.com/\($0)") }; tab.navigationIndex = 250 }
    s.repair()
    let restored = try XCTUnwrap(s.tab(a.id))
    XCTAssertEqual(restored.navigation.count,100)
    XCTAssertEqual(restored.navigationIndex,49)
    XCTAssertEqual(restored.navigation[49].url,a.url)
  }
  func testRestoreLimitAndFailedPeekPromotionDoNotLoseSavedEntries() throws {
    let s = try store(), source = try tab(s,"source"), archived = try tab(s,"archived")
    s.closeTab(id:archived.id); s.setPeek(tabID:source.id,address:"https://example.com/peek")
    for i in 1..<1000 { s.state.tabs.append(BrowserTab(id:"fill-\(i)",spaceID:"home",url:"https://example.com/\(i)")) }
    XCTAssertNil(s.restoreTab(id:archived.id))
    XCTAssertEqual(s.state.archive.first?.id,archived.id)
    XCTAssertNil(s.promotePeek(tabID:source.id))
    XCTAssertNotNil(s.tab(source.id)?.peek)
  }
  func testPortableCollectionMergesAndDropsPrivateHistoryPathsAndPermissions() throws {
    let source = try store(), a = try tab(source,"public")
    source.navigate(tabID:a.id,address:"https://example.com/history")
    source.setPeek(tabID:a.id,address:"https://example.com/peek")
    source.setPermission(profileID:"default",origin:"https://example.com",permission:"camera",allowed:true)
    source.recordDownload(.init(profileID:"default",url:a.url,filename:"private-path",path:"/Users/private-path"))
    _ = source.createProfile(name:"Secret",isPrivate:true); _ = try tab(source,"secret")
    let file = source.directory.appendingPathComponent("portable.json"); try source.exportData(to:file)
    let raw = try String(contentsOf:file,encoding:.utf8)
    for forbidden in ["Secret","private-path","navigation","permissions","downloads"] { XCTAssertFalse(raw.contains(forbidden),forbidden) }
    let destination = try store(), existing = try tab(destination,"existing")
    destination.updateSettings { $0.archiveAfterHours = 72; $0.searchEngine = .bing }
    try destination.importData(from:file)
    XCTAssertEqual(destination.state.activeTabID,existing.id)
    XCTAssertEqual(destination.state.settings.searchEngine,.bing)
    XCTAssertEqual(destination.state.settings.archiveAfterHours,72)
    XCTAssertEqual(destination.state.tabs.count,2)
    let imported = try XCTUnwrap(destination.state.tabs.first { $0.id != existing.id })
    XCTAssertNotEqual(imported.id,a.id)
    XCTAssertEqual(imported.navigation.count,1)
    XCTAssertNotNil(imported.peek)
    XCTAssertEqual(destination.state.profiles.last?.archiveAfterHours,12)
  }
  func testPortableWrongVersionIsRejectedWithoutMutation() throws {
    let s = try store(), before = s.state
    let file = s.directory.appendingPathComponent("future.json")
    try Data(#"{"format":"zacro-export","version":2,"profiles":[],"spaces":[],"tabs":[]}"#.utf8).write(to:file)
    XCTAssertThrowsError(try s.importData(from:file))
    XCTAssertEqual(s.state,before)
  }
  func testHTMLBookmarksDecodeAndDeduplicateOnlyWithinProfile() throws {
    let s = try store(), file = s.directory.appendingPathComponent("bookmarks.html")
    try Data(#"<a href="https://example.com/?a=1&amp;b=2">Hello <b>&#x1f34e;</b></a><a href='javascript:alert(1)'>bad</a><a href="https://example.com/?a=1&amp;b=2">Duplicate</a>"#.utf8).write(to:file)
    try s.importData(from:file); try s.importData(from:file)
    XCTAssertEqual(s.state.bookmarks.count,1)
    XCTAssertEqual(s.state.bookmarks.first?.title,"Hello 🍎")
    XCTAssertEqual(s.state.bookmarks.first?.url,"https://example.com/?a=1&b=2")
    _ = s.createProfile(name:"Work"); try s.importData(from:file)
    XCTAssertEqual(s.state.bookmarks.count,2)
  }
  func testArchiveNeverAndProfileOverridesSurviveRestart() throws {
    let s = try store(), personal = try tab(s,"personal")
    s.setArchiveHours(profileID:"default",hours:0)
    let work = s.createProfile(name:"Work"), old = try tab(s,"old")
    s.setArchiveHours(profileID:work.id,hours:12); _ = try tab(s,"active")
    for i in s.state.tabs.indices { s.state.tabs[i].lastAccessedAt = Date().addingTimeInterval(-48*3600) }
    s.save(); let reopened = BrowserStore(directory:s.directory); reopened.archiveStale()
    XCTAssertNotNil(reopened.tab(personal.id))
    XCTAssertNil(reopened.tab(old.id))
    XCTAssertEqual(reopened.state.archive.first?.id,old.id)
    XCTAssertEqual(reopened.archiveHours(profileID:"default"),0)
  }
  func testSessionRestoreOffKeepsSplitsPeeksAndPinsAndArchivesOrdinaryTabs() throws {
    let s = try store(), a = try tab(s,"a"), b = try tab(s,"b"), c = try tab(s,"c"), d = try tab(s,"d"), e = try tab(s,"e")
    s.setSplit(left:a.id,right:b.id); s.setPeek(tabID:c.id,address:"https://example.com/peek"); s.togglePin(id:d.id)
    s.updateSettings { $0.restoreSession = false }
    let reopened = BrowserStore(directory:s.directory)
    XCTAssertEqual(Set(reopened.state.tabs.map(\.id)),Set([a.id,b.id,c.id,d.id]))
    XCTAssertEqual(reopened.state.archive.first?.id,e.id)
    XCTAssertNil(reopened.state.activeTabID)
  }
  func testSidebarOrderMatchesFolderPinsSplitRowsAndHiddenDrafts() throws {
    let s = try store(), loose = try tab(s,"loose"), favorite = try tab(s,"favorite")
    s.toggleFavorite(id:favorite.id)
    let folder = s.createFolder(name:"Folder"), folderTab = try tab(s,"folder")
    s.moveTab(id:folderTab.id,folderID:folder.id)
    let pinned = try tab(s,"pinned"); s.togglePin(id:pinned.id)
    let first = try tab(s,"first"), second = try tab(s,"second"), third = try tab(s,"third")
    s.setSplit(left:first.id,right:second.id); s.setSplit(left:favorite.id,right:third.id)
    _ = s.createTab()
    XCTAssertEqual(s.sidebarTabs().map(\.id),[folderTab.id,pinned.id,first.id,second.id,favorite.id,third.id,loose.id])
    let other = s.createSpace(name:"Other")
    XCTAssertEqual(s.sidebarTabs(spaceID:other.id).map(\.id),[favorite.id])
  }
  func testExtensionPagePolicyAndPersistentIdentity() throws {
    let s = try store(), url = "chrome-extension://" + String(repeating:"a",count:32) + "/options.html"
    XCTAssertNil(BrowserAddress.resolve(url))
    let tab = try XCTUnwrap(s.createExtensionTab(url:url,title:"Options"))
    s.save(); let reopened = BrowserStore(directory:s.directory)
    XCTAssertEqual(reopened.tab(tab.id)?.url,url)
    for invalid in ["chrome-extension://abc/a", "chrome-extension://" + String(repeating:"a",count:32) + ":90/a", "chrome-extension://" + String(repeating:"a",count:32) + "/zacro-compat-private.js"] {
      XCTAssertNil(BrowserAddress.extensionURL(invalid))
    }
  }
  func testShortcutAliasesReservedKeysSwapsAndRestorationConflicts() throws {
    for entry in BrowserShortcut.defaults { XCTAssertNoThrow(try BrowserShortcut.updating([:],id:entry.id,accelerator:entry.accelerator),entry.id) }
    var bindings = try BrowserShortcut.updating([:],id:"command-palette",accelerator:"Mod+Alt+T")
    bindings = try BrowserShortcut.updating(bindings,id:"sidebar-toggle",accelerator:"Mod+K")
    XCTAssertThrowsError(try BrowserShortcut.updating(bindings,id:"command-palette",accelerator:"Mod+T"))
    XCTAssertEqual(BrowserShortcut.catalog(overrides:bindings).first { $0.id == "command-palette" }?.aliases,[])
    for reserved in ["Mod+C","Mod+Q","Mod+Space","Mod+Shift+3"] { XCTAssertThrowsError(try BrowserShortcut.updating([:],id:"sidebar-toggle",accelerator:reserved)) }
    var swap = try BrowserShortcut.updating([:],id:"sidebar-toggle",accelerator:"")
    swap = try BrowserShortcut.updating(swap,id:"save-page",accelerator:"Mod+S")
    swap = try BrowserShortcut.updating(swap,id:"sidebar-toggle",accelerator:"Mod+Shift+S")
    XCTAssertEqual(BrowserShortcut.sanitized(swap),swap)
  }
  func testSiteSearchValidationEncodingAndCurrentOrigin() throws {
    let saved = SiteSearchEngine(name:"Example",keyword:"ex",url:"https://example.com/search?q=%s")
    XCTAssertNil(saved.validationError)
    XCTAssertEqual(saved.searchURL("a & b")?.absoluteString,"https://example.com/search?q=a%20%26%20b")
    XCTAssertEqual(SiteSearchEngine.currentWebsite("https://example.com/page",engines:[saved],searchEngine:.google)?.id,saved.id)
    let fallback = SiteSearchEngine.currentWebsite("https://other.example/page",engines:[saved],searchEngine:.bing)
    XCTAssertEqual(fallback?.searchURL("test")?.absoluteString,"https://www.bing.com/search?q=site%3Aother.example%20test")
    for address in ["http://remote.example/?q=%s","https://user:password@example.com/?q=%s","https://%s.example.com/","https://example.com/#%s","https://example.com/?q=%s&also=%s"] {
      XCTAssertNotNil(SiteSearchEngine(name:"Example",keyword:"ex",url:address).validationError,address)
    }
  }
  func testDebouncedSaveFlushesLatestSnapshotAndPrivacyClearCannotResurrectHistory() async throws {
    let directory = try directory()
    let store = BrowserStore(directory: directory)
    store.enableDebouncedPersistence(delay: 0.02)
    let tab = try XCTUnwrap(store.createTab(address: "https://first.example"))
    store.navigate(tabID: tab.id, address: "https://second.example")
    try await Task.sleep(nanoseconds: 60_000_000)
    store.navigate(tabID: tab.id, address: "https://final.example")
    try store.flush()
    let loaded = BrowserStore(directory: directory)
    XCTAssertEqual(loaded.tab(tab.id)?.url, "https://final.example/")
    XCTAssertEqual(loaded.state.history.count, store.state.history.count)
    store.clearHistory()
    try await Task.sleep(nanoseconds: 80_000_000)
    let primary = try Data(contentsOf: directory.appendingPathComponent("native-state.json"))
    let backup = try Data(contentsOf: directory.appendingPathComponent("native-state.json.bak"))
    for data in [primary, backup] { XCTAssertTrue(try JSONDecoder().decode(BrowserState.self, from: data).history.isEmpty) }
  }

  func testDurableCommitPublishesOnlyAfterSuccessfulWriteAndPreservesPriorStateOnFailure() throws {
    let directory = try directory()
    let store = BrowserStore(directory: directory)
    try store.commit { _ in }
    let original = store.state
    var draft = original.spaces[0]
    draft.name = "Focused"; draft.icon = "star"; draft.theme.primaryColor = "#12ab78"
    var appearance = original.settings
    appearance.appearance = "dark"; appearance.pageGutter = 7
    // Preview uses value copies; opening, editing or cancelling cannot persist.
    XCTAssertEqual(store.state, original)
    XCTAssertEqual(BrowserStore(directory: directory).state.spaces[0], original.spaces[0])
    try store.commit { state in state.spaces[0] = draft; state.settings = appearance }
    let saved = BrowserStore(directory: directory).state
    XCTAssertEqual(saved.spaces[0], draft)
    XCTAssertEqual(saved.settings.appearance, "dark")
    XCTAssertEqual(saved.settings.pageGutter, 7)
    let prior = store.state
    let stateFile = directory.appendingPathComponent("native-state.json")
    let bytes = try Data(contentsOf:stateFile)
    try FileManager.default.removeItem(at: stateFile)
    try FileManager.default.createDirectory(at:stateFile,withIntermediateDirectories:false)
    draft.name = "Unsaved"; draft.icon = "sun.max"; draft.theme.primaryColor = "#ff00aa"
    appearance.appearance = "light"
    XCTAssertThrowsError(try store.commit { $0.spaces[0] = draft; $0.settings = appearance })
    XCTAssertEqual(store.state, prior)
    XCTAssertNotNil(store.lastError)
    try FileManager.default.removeItem(at:stateFile); try bytes.write(to:stateFile,options:.atomic)
    let restored = BrowserStore(directory:directory).state
    XCTAssertEqual(restored.spaces[0], prior.spaces[0])
    XCTAssertEqual(restored.settings.appearance, prior.settings.appearance)
  }

  func testRestartInterruptsUnfinishedDownloadsAndSettingsUseOriginalRounding() throws {
    let s = try store()
    s.recordDownload(.init(profileID: "default", url: "https://example.com/file", filename: "file", status: "downloading"))
    s.recordDownload(.init(profileID: "default", url: "https://example.com/complete", filename: "complete", status: "completed"))
    s.updateSettings { $0.pageGutter = 6.8; $0.pageRadius = 10.1; $0.sidebarWidth = 224.6; $0.panelWidth = 400.2; $0.motionScale = 1.246 }
    XCTAssertEqual(s.state.downloads.last?.status, "downloading")
    let restored = BrowserStore(directory: s.directory)
    XCTAssertEqual(restored.state.downloads.first?.status, "complete")
    XCTAssertEqual(restored.state.downloads.last?.status, "interrupted")
    XCTAssertEqual(restored.state.settings.pageGutter, 7)
    XCTAssertEqual(restored.state.settings.pageRadius, 10)
    XCTAssertEqual(restored.state.settings.sidebarWidth, 225)
    XCTAssertEqual(restored.state.settings.panelWidth, 400)
    XCTAssertEqual(restored.state.settings.motionScale, 1.25)
    let engine = SiteSearchEngine(name: "Search", keyword: "s", url: "https://EXAMPLE.com:443/search?q=%s")
    XCTAssertEqual(SiteSearchEngine.currentWebsite("https://example.com/article", engines: [engine], searchEngine: .google)?.id, engine.id)
  }

  func testImportFailureDoesNotPublishPartialCollection() throws {
    let s = try store(), source = try store()
    _ = try tab(source, "import")
    let file = try directory().appendingPathComponent("export.json")
    try source.exportData(to: file)
    let prior = s.state
    try FileManager.default.removeItem(at: s.directory)
    try Data("blocked directory".utf8).write(to: s.directory)
    XCTAssertThrowsError(try s.importData(from: file))
    XCTAssertEqual(s.state, prior)
  }

  func testPrivacyOperationsRejectRecoveryWriteFailureWithoutChangingPrimaryOrMemory() throws {
    let s = try store(), tab = try tab(s, "history")
    s.navigate(tabID: tab.id, address: "https://example.com/next")
    s.closeTab(id: tab.id)
    s.setPermission(profileID: "default", origin: "https://example.com", permission: "camera", allowed: true)
    let profile = s.createProfile(name: "Other")
    try s.flush()
    let original = s.state, file = s.directory.appendingPathComponent("native-state.json"), backup = s.directory.appendingPathComponent("native-state.json.bak")
    let primary = try Data(contentsOf: file)
    try FileManager.default.removeItem(at: backup)
    try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: backup.appendingPathComponent("block"))
    let operations: [() throws -> Void] = [
      { try s.clearHistoryDurably(profileID: "default") },
      { try s.clearArchiveDurably(profileID: "default") },
      { try s.clearPermissionsDurably(profileID: "default") },
      { try s.removePermissionDurably(id: original.permissions[0].id) },
      { try s.deleteProfileDurably(id: profile.id) }
    ]
    for operation in operations {
      XCTAssertThrowsError(try operation())
      XCTAssertEqual(s.state, original)
      XCTAssertEqual(try Data(contentsOf: file), primary)
    }
    try FileManager.default.removeItem(at: backup)
    try s.clearPermissionsDurably(profileID: "default")
    XCTAssertTrue(s.state.permissions.isEmpty)
    XCTAssertTrue(try JSONDecoder().decode(BrowserState.self, from: Data(contentsOf: backup)).permissions.isEmpty)
  }

  func testAddressHostClassificationAndTrustedExtensionDuplication() throws {
    XCTAssertEqual(BrowserAddress.resolve("localhostevil")?.absoluteString, "https://www.google.com/search?q=localhostevil")
    XCTAssertEqual(BrowserAddress.resolve("src/file.swift")?.absoluteString, "https://www.google.com/search?q=src%2Ffile.swift")
    XCTAssertNil(BrowserAddress.webURL("https://example.com:99999/path"))
    let s = try store(), url = "chrome-extension://" + String(repeating: "a", count: 32) + "/options.html"
    let original = try XCTUnwrap(s.createExtensionTab(url: url, title: "Options"))
    let copy = try XCTUnwrap(s.duplicateTab(id: original.id))
    XCTAssertNotEqual(original.id, copy.id)
    XCTAssertEqual(copy.url, url)
  }

  func testArchiveCandidatesRespectRuntimeExclusionsAndVisibleSplitReadingActivity() throws {
    let s = try store(), safe = try tab(s, "safe"), protected = try tab(s, "playing"), left = try tab(s, "left"), right = try tab(s, "right")
    let now = Date(), stale = now.addingTimeInterval(-48 * 3600)
    for id in [safe.id, protected.id, left.id, right.id] { s.updateTab(id) { $0.lastAccessedAt = stale } }
    s.setSplit(left: left.id, right: right.id)
    s.updateTab(left.id) { $0.lastAccessedAt = stale }; s.updateTab(right.id) { $0.lastAccessedAt = stale }
    XCTAssertEqual(Set(s.archiveCandidates(now: now, excludeIDs: [protected.id]).map(\.id)), [safe.id])
    s.recordVisibleTabActivity(now: now)
    XCTAssertEqual(s.tab(left.id)?.lastAccessedAt, now)
    XCTAssertEqual(s.tab(right.id)?.lastAccessedAt, now)
    s.unsplit(tabID: left.id)
    s.archiveStale(now: now, excludeIDs: [protected.id])
    XCTAssertNil(s.tab(safe.id))
    XCTAssertNotNil(s.tab(protected.id))
    XCTAssertNotNil(s.tab(right.id))
  }

  func testMutationTitlesAndNamesAreBoundedBeforeSaving() throws {
    let s = try store(), name = String(repeating: "x", count: 400), title = String(repeating: "t", count: 900)
    let profile = s.createProfile(name: name)
    XCTAssertEqual(profile.name.count, 200)
    let space = s.createSpace(name: name)
    XCTAssertEqual(space.name.count, 200)
    let folder = s.createFolder(name: name)
    XCTAssertEqual(folder.name.count, 200)
    let page = try tab(s, "title")
    s.navigate(tabID: page.id, address: "https://example.com/new", title: title)
    XCTAssertEqual(s.tab(page.id)?.title.count, 500)
    XCTAssertEqual(s.state.history.first?.title.count, 500)
    s.updateTab(page.id) { $0.title = title; $0.customTitle = title }
    XCTAssertEqual(s.tab(page.id)?.customTitle?.count, 500)
  }

  func testCanonicalOriginsAndNavigationSurviveChromiumNormalization() throws {
    XCTAssertEqual(BrowserAddress.webURL("HTTPS://EXAMPLE.COM:443")?.absoluteString, "https://example.com/")
    XCTAssertEqual(BrowserAddress.webOrigin("http://EXAMPLE.com:80/path?q=1#fragment"), "http://example.com")
    let s = try store(), page = try tab(s, "navigation")
    s.updateTab(page.id) { tab in
      tab.url = "https://EXAMPLE.com:443"
      tab.navigation = [.init(url: "https://example.com/before"), .init(url: "https://example.com"), .init(url: "https://example.com/after")]
      tab.navigationIndex = 1
    }
    s.repair()
    XCTAssertEqual(s.tab(page.id)?.url, "https://example.com/")
    XCTAssertEqual(s.tab(page.id)?.navigationIndex, 1)
    XCTAssertEqual(s.forward(tabID: page.id), "https://example.com/after")
    s.setPermission(profileID: "default", origin: "HTTPS://EXAMPLE.COM:443/somewhere", permission: "camera", allowed: true)
    XCTAssertEqual(s.savedPermission(profileID: "default", origin: "https://example.com", permission: "camera"), true)
    s.toggleBookmark(url: "HTTPS://EXAMPLE.COM:443", title: "Example")
    s.toggleBookmark(url: "https://example.com/", title: "Example")
    XCTAssertTrue(s.state.bookmarks.isEmpty)
  }

}
