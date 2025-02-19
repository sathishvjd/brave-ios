// Copyright 2022 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import Combine
import Data
import BraveCore
import Shared
import BraveShared
import os.log

/// An object responsible for fetching filer lists resources from multiple sources
public class FilterListResourceDownloader: ObservableObject {
  private class FilterListSettingsManager {
    /// Wether or not these settings are stored in memory or persisted
    private let inMemory: Bool
    
    /// A list of defaults that should be set once we load the filter lists.
    /// This is here in case the filter lists are not loaded but the user is already changing settings
    @MainActor var pendingDefaults: [String: Bool] = [:]
    
    /// This is a list of all available settings.
    ///
    /// - Warning: Do not call this before we load core data
    @MainActor public lazy var allFilterListSettings: [FilterListSetting] = {
      return FilterListSetting.loadAllSettings(fromMemory: inMemory)
    }()
    
    init(inMemory: Bool) {
      self.inMemory = inMemory
    }
    
    /// Get the enabled status of a filter list setting without modifying any other property
    ///
    /// - Warning: Do not call this before we load core data
    @MainActor public func isEnabled(forUUID uuid: String) -> Bool {
      return allFilterListSettings.first(where: { $0.uuid == uuid })?.isEnabled ?? false
    }
    
    /// - Warning: Do not call this before we load core data
    @MainActor public func isEnabled(for componentID: String) -> Bool {
      return allFilterListSettings.first(where: { $0.componentId == componentID })?.isEnabled ?? false
    }
    
    /// Set the enabled status of a filter list setting
    /// Otherwise it will create a new setting with the specified properties
    ///
    /// - Warning: Do not call this before we load core data
    @MainActor public func upsertSetting(uuid: String, isEnabled: Bool) {
      if let index = allFilterListSettings.firstIndex(where: { $0.uuid == uuid }) {
        updateSetting(
          uuid: uuid,
          isEnabled: isEnabled,
          componentId: allFilterListSettings[index].componentId
        )
      } else {
        create(
          uuid: uuid,
          componentId: nil,
          isEnabled: isEnabled
        )
      }
    }
    
    /// Set the enabled status and componentId of a filter list setting if the setting exists.
    /// Otherwise it will create a new setting with the specified properties
    ///
    /// - Warning: Do not call this before we load core data
    @MainActor public func upsertSetting(uuid: String, isEnabled: Bool, componentId: String?, allowCreation: Bool) {
      if allFilterListSettings.contains(where: { $0.uuid == uuid }) {
        updateSetting(
          uuid: uuid,
          isEnabled: isEnabled,
          componentId: componentId
        )
      } else if allowCreation {
        create(
          uuid: uuid,
          componentId: componentId,
          isEnabled: isEnabled
        )
      }
    }
    
    /// Set the enabled status of a filter list setting
    ///
    /// - Warning: Do not call this before we load core data
    @MainActor public func set(folderURL: URL, forUUID uuid: String) {
      guard let index = allFilterListSettings.firstIndex(where: { $0.uuid == uuid }) else {
        return
      }
      
      guard allFilterListSettings[index].folderURL != folderURL else { return }
      allFilterListSettings[index].folderURL = folderURL
      FilterListSetting.save(inMemory: inMemory)
    }
    
    @MainActor private func updateSetting(uuid: String, isEnabled: Bool, componentId: String?) {
      guard let index = allFilterListSettings.firstIndex(where: { $0.uuid == uuid }) else {
        return
      }
      
      guard allFilterListSettings[index].isEnabled != isEnabled || allFilterListSettings[index].componentId != componentId else {
        // Ensure we stop if this is already in sync in order to avoid an event loop
        // And things hanging for too long.
        // This happens because we care about UI changes but not when our downloads finish
        return
      }
        
      allFilterListSettings[index].isEnabled = isEnabled
      allFilterListSettings[index].componentId = componentId
      FilterListSetting.save(inMemory: inMemory)
    }
    
    /// Create a filter list setting for the given UUID and enabled status
    @MainActor private func create(uuid: String, componentId: String?, isEnabled: Bool) {
      let setting = FilterListSetting.create(uuid: uuid, componentId: componentId, isEnabled: isEnabled, inMemory: inMemory)
      allFilterListSettings.append(setting)
    }
  }
  
  /// A shared instance of this class
  ///
  /// - Warning: You need to wait for `DataController.shared.initializeOnce()` to be called before using this instance
  public static let shared = FilterListResourceDownloader()
  
  /// Object responsible for getting component updates
  private var adBlockService: AdblockService?
  /// Manager that handles updates to filter list settings in core data
  private let settingsManager: FilterListSettingsManager
  /// The resource downloader that downloads our resources
  private let resourceDownloader: ResourceDownloader
  /// The filter list subscription
  private var filterListSubscription: AnyCancellable?
  /// Fetch content blocking tasks per filter list
  private var fetchTasks: [ResourceDownloader.Resource: Task<Void, Error>]
  /// Ad block service tasks per filter list UUID
  private var adBlockServiceTasks: [String: Task<Void, Error>]
  /// A marker that says if fetching has started
  private var startedFetching = false
  /// The filter lists wrapped up so we can contain
  @Published var filterLists: [FilterList]
  
  /// A formatter that is used to format a version number
  private lazy var fileVersionDateFormatter: DateFormatter = {
    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.dateFormat = "yyyy.MM.dd.HH.mm.ss"
    dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    return dateFormatter
  }()
  
  init(networkManager: NetworkManager = NetworkManager(), persistChanges: Bool = true) {
    self.resourceDownloader = ResourceDownloader(networkManager: networkManager)
    self.settingsManager = FilterListSettingsManager(inMemory: !persistChanges)
    self.filterLists = []
    self.fetchTasks = [:]
    self.adBlockServiceTasks = [:]
    self.adBlockService = nil
    self.recordP3ACookieListEnabled()
  }
  
  public func loadCachedData() async {
    async let cachedFilterLists: Void = self.loadCachedFilterLists()
    async let cachedDefaultFilterList: Void = self.loadCachedDefaultFilterList()
    _ = await (cachedFilterLists, cachedDefaultFilterList)
  }
  
  /// Tells us if the filter list is enabled for the given `UUID`
  @MainActor public func isEnabled(filterListUUID uuid: String) -> Bool {
    return settingsManager.isEnabled(forUUID: uuid)
  }
  
  private func loadCachedFilterLists() async {
    let settingsInfo: [(index: Int, uuid: String, folderURL: URL?, resources: [ResourceDownloader.Resource])] = await MainActor.run {
      let filterListSettings = settingsManager.allFilterListSettings
      
      return filterListSettings.enumerated().compactMap { (index, setting) in
        guard setting.isEnabled else { return nil }
        return (index, setting.uuid, setting.folderURL, setting.resources)
      }
    }
    
    return await withTaskGroup(of: Void.self) { group in
      for settingInfo in settingsInfo {
        group.addTask {
          // Load cached component updater files
          if let folderURL = settingInfo.folderURL, FileManager.default.fileExists(atPath: folderURL.path) {
            await self.handle(downloadedFolderURL: folderURL, forFilterListUUID: settingInfo.uuid, index: settingInfo.index)
          }
          
          // Load cached download resources
          await withTaskGroup(of: Void.self) { group in
            for resource in settingInfo.resources {
              group.addTask {
                guard let fileURL = ResourceDownloader.downloadedFileURL(for: resource) else { return }
                let date = try? ResourceDownloader.creationDate(for: resource)
                await self.handle(downloadedFileURL: fileURL, for: resource, filterListUUID: settingInfo.uuid, date: date, index: settingInfo.index)
              }
            }
          }
        }
        
      }
    }
  }
  
  private func loadCachedDefaultFilterList() async {
    guard let folderURL = FilterListSetting.makeFolderURL(
      forFilterListFolderPath: Preferences.AppState.lastDefaultFilterListFolderPath.value
    ), FileManager.default.fileExists(atPath: folderURL.path) else {
      return
    }
    
    await loadShields(fromFolderURL: folderURL)
  }
  
  /// Start the resource subscriber.
  ///
  /// - Warning: You need to wait for `DataController.shared.initializeOnce()` to be called before invoking this method
  @MainActor public func start(with adBlockService: AdblockService) {
    self.adBlockService = adBlockService
    
    if let folderPath = adBlockService.shieldsInstallPath {
      didUpdateShieldComponent(folderPath: folderPath, adBlockFilterLists: adBlockService.regionalFilterLists ?? [])
    }
    
    adBlockService.shieldsComponentReady = { folderPath in
      guard let folderPath = folderPath else { return }
      
      Task { @MainActor in
        self.didUpdateShieldComponent(folderPath: folderPath, adBlockFilterLists: adBlockService.regionalFilterLists ?? [])
      }
    }
  }
  
  /// Enables a filter list for the given component ID. Returns true if the filter list exists or not.
  @MainActor public func enableFilterList(for componentID: String, isEnabled: Bool) {
    // Enable the setting
    defer { self.recordP3ACookieListEnabled() }
    if let index = filterLists.firstIndex(where: { $0.componentId == componentID }) {
      // Only update the value if it has changed
      guard filterLists[index].isEnabled != isEnabled else { return }
      filterLists[index].isEnabled = isEnabled
    } else {
      // We haven't loaded the filter lists yet. Add it to the pending list.
      settingsManager.pendingDefaults[componentID] = isEnabled
    }
  }
  
  /// Tells us if the filter list is enabled for the given `componentID`
  @MainActor public func isEnabled(for componentID: String) -> Bool {
    return settingsManager.isEnabled(for: componentID)
  }
  
  /// Invoked when shield components are loaded
  ///
  /// This function will start fetching data and subscribe publishers once if it hasn't already done so.
  @MainActor private func didUpdateShieldComponent(folderPath: String, adBlockFilterLists: [AdblockFilterListCatalogEntry]) {
    if !startedFetching && !adBlockFilterLists.isEmpty {
      startedFetching = true
      let filterLists = loadFilterLists(from: adBlockFilterLists, filterListSettings: settingsManager.allFilterListSettings)
      self.filterLists = filterLists
      self.subscribeToFilterListChanges()
      self.registerAllEnabledFilterLists()
    }
    
    let folderURL = URL(fileURLWithPath: folderPath)
    let folderSubPath = FilterListSetting.extractFolderPath(fromFilterListFolderURL: folderURL)
    Preferences.AppState.lastDefaultFilterListFolderPath.value = folderSubPath
    
    Task {
      await self.loadShields(fromFolderURL: folderURL)
    }
  }
  
  /// Load shields with the given `AdblockService` folder `URL`
  private func loadShields(fromFolderURL folderURL: URL) async {
    let version = folderURL.lastPathComponent
    
    // Lets add these new resources
    await AdBlockEngineManager.shared.add(
      resource: AdBlockEngineManager.Resource(type: .dat, source: .adBlock),
      fileURL: folderURL.appendingPathComponent("rs-ABPFilterParserData.dat"),
      version: version
    )
    
    await AdBlockEngineManager.shared.add(
      resource: AdBlockEngineManager.Resource(type: .jsonResources, source: .adBlock),
      fileURL: folderURL.appendingPathComponent("resources.json"),
      version: version
    )
  }
  
  /// This method allows us to enable selected lists by default for new users.
  /// Make sure you use componentID to identify the filter list, as `uuid` will be deprecated in the future.
  @MainActor private func newFilterListDefault(for componentId: String) -> Bool {
    if let value = settingsManager.pendingDefaults[componentId] {
      return value
    }
    
    let componentIDsToOverride = [FilterList.mobileAnnoyancesComponentID]
    return componentIDsToOverride.contains(componentId) ? true : false
  }
  
  /// Load filter lists from the ad block service
  @MainActor private func loadFilterLists(from regionalFilterLists: [AdblockFilterListCatalogEntry], filterListSettings: [FilterListSetting]) -> [FilterList] {
    return regionalFilterLists.map { adBlockFilterList in
      let setting = filterListSettings.first(where: { $0.uuid == adBlockFilterList.uuid })
      return FilterList(
        from: adBlockFilterList,
        isEnabled: setting?.isEnabled ?? newFilterListDefault(for: adBlockFilterList.componentId)
      )
    }
  }
  
  /// Subscribe to the UI changes on the `filterLists` so that we can save settings and register or unregister the filter lists
  private func subscribeToFilterListChanges() {
    // Subscribe to changes on the filter list states
    filterListSubscription = $filterLists
      .sink { filterLists in
        DispatchQueue.main.async { [weak self] in
          for filterList in filterLists {
            self?.handleUpdate(to: filterList)
          }
        }
      }
  }
  
  /// Ensures settings are saved for the given filter list and that our publisher is aware of the changes
  @MainActor private func handleUpdate(to filterList: FilterList) {
    // Upsert (update or insert) the setting.
    //
    // However we create only when:
    // a) The filter list is enabled
    //    (this is because loading caches are based on created settings)
    // b) The filter list is different than the default
    //    (in order to respect the users preference if the default were to change in the future)
    settingsManager.upsertSetting(
      uuid: filterList.uuid,
      isEnabled: filterList.isEnabled,
      componentId: filterList.componentId,
      allowCreation: filterList.isEnabled || newFilterListDefault(for: filterList.componentId) != filterList.isEnabled
    )
    
    // Register or unregister the filter list depending on its toggle state
    if filterList.isEnabled {
      register(filterList: filterList)
    } else {
      unregister(filterList: filterList)
    }
  }
  
  /// Register all enabled filter lists
  @MainActor private func registerAllEnabledFilterLists() {
    for filterList in filterLists {
      guard filterList.isEnabled else { continue }
      register(filterList: filterList)
    }
  }
  
  /// Register this filter list and start all additional resource downloads
  @MainActor private func register(filterList: FilterList) {
    guard adBlockServiceTasks[filterList.uuid] == nil else { return }
    guard let adBlockService = adBlockService else { return }
    guard let index = filterLists.firstIndex(where: { $0.uuid == filterList.uuid }) else { return }
    
    for resource in filterList.resources {
      startFetching(resource: resource, for: filterList, index: index)
    }

    adBlockServiceTasks[filterList.uuid] = Task { @MainActor in
      for await folderURL in await adBlockService.register(filterListUUID: filterList.uuid) {
        guard let folderURL = folderURL else { continue }
        guard self.isEnabled(filterListUUID: filterList.uuid) else { return }
        await self.handle(downloadedFolderURL: folderURL, forFilterListUUID: filterList.uuid, index: index)
        
        // Save the downloaded folder for later (caching) purposes
        self.settingsManager.set(folderURL: folderURL, forUUID: filterList.uuid)
      }
    }
  }
  
  /// Unregister, cancel all of its downloads and remove any `ContentBlockerManager` and `AdBlockEngineManager` resources for this filter list
  @MainActor private func unregister(filterList: FilterList) {
    adBlockServiceTasks[filterList.uuid]?.cancel()
    adBlockServiceTasks.removeValue(forKey: filterList.uuid)
    
    for resource in filterList.resources {
      stopFetching(resource: resource)
    }
    
    Task {
      async let removeContentBlockerResource: Void = ContentBlockerManager.shared.removeResource(for: .filterList(uuid: filterList.uuid))
      async let removeAdBlockEngineResource: Void = AdBlockEngineManager.shared.removeResources(for: .filterList(uuid: filterList.uuid))
      _ = await (removeContentBlockerResource, removeAdBlockEngineResource)
    }
  }
  
  /// Start fetching the resource for the given filter list
  private func startFetching(resource: ResourceDownloader.Resource, for filterList: FilterList, index: Int) {
    guard fetchTasks[resource] == nil else {
      // We're already fetching for this filter list
      return
    }
    
    fetchTasks[resource] = Task { @MainActor in
      if let fileURL = ResourceDownloader.downloadedFileURL(for: resource) {
        await self.handle(downloadedFileURL: fileURL, for: resource, filterListUUID: filterList.uuid, index: index)
      }
      
      try await withTaskCancellationHandler(operation: {
        for try await result in await self.resourceDownloader.downloadStream(for: resource) {
          switch result {
          case .success(let downloadResult):
            await self.handle(
              downloadedFileURL: downloadResult.fileURL,
              for: resource, filterListUUID: filterList.uuid,
              date: downloadResult.date,
              index: index
            )
          case .failure(let error):
            Logger.module.error("\(error.localizedDescription)")
          }
        }
      }, onCancel: {
        self.fetchTasks.removeValue(forKey: resource)
      })
    }
  }
  
  /// Cancel all fetching tasks for the given resource
  private func stopFetching(resource: ResourceDownloader.Resource) {
    fetchTasks[resource]?.cancel()
    fetchTasks.removeValue(forKey: resource)
  }
  
  /// Handle resource downloads for the given filter list
  private func handle(downloadedFileURL: URL, for resource: ResourceDownloader.Resource, filterListUUID uuid: String, date: Date? = nil, index: Int) async {
    guard await isEnabled(filterListUUID: uuid) else {
      return
    }
    
    let version = date != nil ? self.fileVersionDateFormatter.string(from: date!) : nil
    
    switch resource {
    case .filterListContentBlockingBehaviors:
      await ContentBlockerManager.shared.set(resource: ContentBlockerManager.Resource(
        url: downloadedFileURL,
        sourceType: .downloaded(version: version)
      ), for: .filterList(uuid: uuid))
      
    case .filterListAdBlockRules:
      // TODO: Compile rulelist to blocklist
      await AdBlockEngineManager.shared.add(
        resource: AdBlockEngineManager.Resource(type: .ruleList, source: .filterList(uuid: uuid)),
        fileURL: downloadedFileURL,
        version: version,
        relativeOrder: index
      )
    default:
      assertionFailure("Should not be handling this resource")
    }
  }
  
  /// Handle the downloaded folder url for the given filter list. The folder URL should point to a `AdblockFilterList` resource
  /// This will also start fetching any additional resources for the given filter list given it is still enabled.
  private func handle(downloadedFolderURL: URL, forFilterListUUID uuid: String, index: Int) async {
    // Let's add the new ones in
    await AdBlockEngineManager.shared.add(
      resource: AdBlockEngineManager.Resource(type: .dat, source: .filterList(uuid: uuid)),
      fileURL: downloadedFolderURL.appendingPathComponent("rs-\(uuid).dat"),
      version: downloadedFolderURL.lastPathComponent, relativeOrder: index
    )
    await AdBlockEngineManager.shared.add(
      resource: AdBlockEngineManager.Resource(type: .jsonResources, source: .filterList(uuid: uuid)),
      fileURL: downloadedFolderURL.appendingPathComponent("resources.json"),
      version: downloadedFolderURL.lastPathComponent,
      relativeOrder: index
    )
  }
  
  // MARK: - P3A
  
  private func recordP3ACookieListEnabled() {
    // Q69 Do you have cookie consent notice blocking enabled?
    Task { @MainActor in
      UmaHistogramBoolean(
        "Brave.Shields.CookieListEnabled",
        isEnabled(for: FilterList.cookieConsentNoticesComponentID)
      )
    }
  }
}

/// Helpful extension to the AdblockService
private extension AdblockService {
  /// Register the filter list given by the uuid and streams its updates
  ///
  /// - Note: Cancelling this task will unregister this filter list from recieving any further updates
  @MainActor func register(filterListUUID uuid: String) async -> AsyncStream<URL?> {
    return AsyncStream { continuation in
      guard let filterList = regionalFilterLists?.first(where: { $0.uuid == uuid }) else {
        continuation.finish()
        return
      }
              
      registerFilterListComponent(filterList) { filterList, folderPath in
        guard let folderPath = folderPath else {
          continuation.yield(nil)
          return
        }
        
        let folderURL = URL(fileURLWithPath: folderPath)
        continuation.yield(folderURL)
      }
      
      continuation.onTermination = { @Sendable _ in
        self.unregisterFilterListComponent(filterList)
      }
    }
  }
}
