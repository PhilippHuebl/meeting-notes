//
//  AppUpdater.swift
//  Meeting Notes
//
//  Created by Philipp Hübl on 16.11.2026.
//

import AppKit
import Sparkle

@MainActor
@Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    private(set) var status: UpdateStatus
    private(set) var lastChecked: Date?
    private(set) var canCheck = false

    let isSetUp: Bool

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var isBusy: @MainActor () -> Bool = { false }
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    private static let busyErrorDomain = "MeetingNotes.AppUpdater"
    private static let retryInterval: Duration = .seconds(600)

    private var updater: SPUUpdater? { controller?.updater }

    override private init() {
        let info = Bundle.main.infoDictionary
        isSetUp = UpdateStatus.isSetUp(publicKey: info?["SUPublicEDKey"] as? String,
                                       feedURL: info?["SUFeedURL"] as? String)
        status = isSetUp ? .idle : .notSetUp
        super.init()
        if isSetUp {
            controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        }
    }

    var automaticChecks: Bool {
        get {
            access(keyPath: \.automaticChecks)
            return updater?.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticChecks) { updater?.automaticallyChecksForUpdates = newValue }
        }
    }

    /// `isBusy` is true during a recording or a final transcript.
    func start(isBusy: @escaping @MainActor () -> Bool) {
        guard let controller, canCheckObservation == nil else { return }
        self.isBusy = isBusy
        controller.startUpdater()
        lastChecked = controller.updater.lastUpdateCheckDate
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in self?.canCheck = updater.canCheckForUpdates }
        }
    }

    func checkNow() {
        guard let updater, updater.canCheckForUpdates else { return }
        status = .checking
        updater.checkForUpdates()
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground, isBusy() else { return }
        retryWhenFree()
        throw NSError(domain: Self.busyErrorDomain, code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "The update check waits until the recording and the transcript are finished."])
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = .available(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        status = .upToDate
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        let error = error as NSError?
        if error?.domain == Self.busyErrorDomain { return }
        lastChecked = updater.lastUpdateCheckDate
        if let error, !Self.isExpected(error) {
            status = .failed(error.localizedDescription)
        } else if status == .checking {
            status = .idle
        }
    }

    // MARK: Helpers

    private static func isExpected(_ error: NSError) -> Bool {
        guard error.domain == SUSparkleErrorDomain else { return false }
        let expected: [SUError] = [.noUpdateError, .installationCanceledError, .installationAuthorizeLaterError]
        return expected.contains { Int($0.rawValue) == error.code }
    }

    /// Sparkle schedules the next check a full interval after a blocked one, so check again as soon as the app is free.
    private func retryWhenFree() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            while let self, self.isBusy() {
                try? await Task.sleep(for: Self.retryInterval)
            }
            self?.retryTask = nil
            self?.updater?.checkForUpdatesInBackground()
        }
    }
}
