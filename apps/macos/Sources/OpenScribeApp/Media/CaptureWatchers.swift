import AppKit
import Foundation

/// The recorder's background observations: the storage and microphone
/// permission ticks, the selected application's exit, and system sleep and
/// wake. Each watch calls back on the main actor and the recorder decides what
/// an observation means.
@MainActor
final class CaptureWatchers {
  /// Cadence of the storage and microphone-permission watches, and of the
  /// permission check while a restored microphone waits for its first sample.
  static let interval: Duration = .seconds(2)

  private var storageTask: Task<Void, Never>?
  private var permissionTask: Task<Void, Never>?
  private var applicationExitObserver: NSObjectProtocol?
  private var powerObservers: [NSObjectProtocol] = []

  /// Calls `tick` after every interval until it returns false or the watch
  /// stops.
  func watchStorage(_ tick: @escaping @Sendable @MainActor () async -> Bool) {
    storageTask?.cancel()
    storageTask = Task {
      while !Task.isCancelled {
        do { try await Task.sleep(for: Self.interval) } catch { return }
        guard await tick() else { return }
      }
    }
  }

  func stopStorage() {
    storageTask?.cancel()
  }

  /// Calls `tick` after every interval until it returns false or the watch
  /// stops. A tick never runs after the watch was stopped.
  func watchPermission(_ tick: @escaping @Sendable @MainActor () async -> Bool) {
    permissionTask = Task {
      while !Task.isCancelled {
        do { try await Task.sleep(for: Self.interval) } catch { return }
        guard !Task.isCancelled, await tick() else { return }
      }
    }
  }

  func stopPermission() {
    permissionTask?.cancel()
    permissionTask = nil
  }

  /// Calls `exited` when the application with `processId` terminates.
  func watchApplicationExit(
    processId: pid_t?, _ exited: @escaping @Sendable @MainActor (pid_t) async -> Void
  ) {
    stopApplicationExit()
    guard let processId else { return }
    applicationExitObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
    ) { notification in
      guard
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        application.processIdentifier == processId
      else { return }
      let exitedId = application.processIdentifier
      Task { @MainActor in await exited(exitedId) }
    }
  }

  /// Ends every watch that belongs to one recording session.
  func stopSession() {
    stopPermission()
    storageTask?.cancel()
    storageTask = nil
    stopApplicationExit()
  }

  /// Observes system sleep and wake for the recorder's lifetime.
  func observePower(
    sleep: @escaping @Sendable @MainActor () async -> Void,
    wake: @escaping @Sendable @MainActor () -> Void
  ) {
    let center = NSWorkspace.shared.notificationCenter
    powerObservers = [
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        _ in
        Task { @MainActor in await sleep() }
      },
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        _ in
        Task { @MainActor in wake() }
      },
    ]
  }

  private func stopApplicationExit() {
    if let applicationExitObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(applicationExitObserver)
    }
    applicationExitObserver = nil
  }
}
