/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// CameraAccessApp.swift
//
// Main entry point for the CameraAccess sample app demonstrating the Meta Wearables DAT SDK.
// This app shows how to connect to wearable devices (like Ray-Ban Meta smart glasses),
// stream live video from their cameras, and capture photos. It provides a complete example
// of DAT SDK integration including device registration, permissions, and media streaming.
//

import ExternalAccessory
import Foundation
import MWDATCore
import Observation
import SwiftUI
import UIKit

#if DEBUG
import MWDATMockDevice
#endif

@main
struct CameraAccessApp: App {
  #if DEBUG
  // Debug menu for simulating device connections during development. The
  // ladybug button toggles `showDebugMenu`; the sheet hosts the mock device kit.
  @State private var showDebugMenu = false
  @State private var mockDeviceKitViewModel = MockDeviceKitViewModel(mockDeviceKit: MockDeviceKit.shared)
  #endif
  private let wearables: WearablesInterface
  @State private var wearablesViewModel: WearablesViewModel
  @State private var voiceLaunch: VoiceLaunchCoordinator

  init() {
    do {
      try Wearables.configure()
    } catch {
      #if DEBUG
      NSLog("[CameraAccess] Failed to configure Wearables SDK: \(error)")
      #endif
    }

    #if DEBUG
    // Start the test server when launched by XCUITests so tests can control
    // mock device setup via HTTP commands from the test process.
    if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
      MockDeviceKit.shared.enable(config: MockDeviceKitConfig(initiallyRegistered: false))

      let portFilePath = ProcessInfo.processInfo.environment["MWDAT_TEST_SERVER_PORT_FILE"]
      Task {
        do {
          _ = try await MockDeviceKit.shared.startTestServer(portFilePath: portFilePath)
        } catch {
          // pika27: errors are not propagated from this unstructured task
        }
      }
    }
    #endif

    let wearables = Wearables.shared
    self.wearables = wearables
    self._wearablesViewModel = State(wrappedValue: WearablesViewModel(wearables: wearables))
    self._voiceLaunch = State(wrappedValue: VoiceLaunchCoordinator(wearables: wearables))
  }

  var body: some Scene {
    WindowGroup {
      // Main app view with access to the shared Wearables SDK instance
      // The Wearables.shared singleton provides the core DAT API
      MainAppView(wearables: Wearables.shared, viewModel: wearablesViewModel, voiceLaunch: voiceLaunch)
        .onAppear { voiceLaunch.start() }
        .onOpenURL { url in
          // A Shortcuts "Open URLs" action can invoke the same one-shot camera
          // flow when Meta AI cannot resolve the app's spoken name.
          if url.scheme?.lowercased() == "cameraaccess", url.host?.lowercased() == "ask",
             url.path.isEmpty || url.path == "/" {
            voiceLaunch.requestVision()
          }
        }
        // Show error alerts for view model failures
        .alert("Something went wrong", isPresented: $wearablesViewModel.showError) {
          Button("OK") {
            wearablesViewModel.dismissError()
          }
        } message: {
          Text(wearablesViewModel.errorMessage)
        }
        // Visible in the sideloaded Release build, not only Xcode Debug builds.
        // Read-only: does not open a camera or create another DAT session.
        .overlay(alignment: .topLeading) {
          ConnectionDiagnosticsView(wearables: wearables)
            .padding(.horizontal, 20)
            .padding(.top, 82)
        }
        #if DEBUG
      .sheet(isPresented: $showDebugMenu) {
        MockDeviceKitView(viewModel: mockDeviceKitViewModel)
      }
      .overlay {
        DebugMenuView(showDebugMenu: $showDebugMenu)
      }
        #endif

      // Registration view handles the flow for connecting to the glasses via Meta AI
      RegistrationView(viewModel: wearablesViewModel)
    }
  }
}

/// Listens at app scope so a cold "Hey Meta, start OpenVision" launch can reach
/// the camera screen without an existing camera session or preview.
@Observable
@MainActor
final class VoiceLaunchCoordinator {
  private(set) var pendingLaunch = false
  private(set) var status = "waiting for glasses"

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private var stream: VoiceInvocationsStream?
  @ObservationIgnored private var invocationToken: (any AnyListenerToken)?
  @ObservationIgnored private var errorToken: (any AnyListenerToken)?
  @ObservationIgnored private var linkTokens: [DeviceIdentifier: any AnyListenerToken] = [:]
  @ObservationIgnored private var deviceTask: Task<Void, Never>?
  @ObservationIgnored private var registrationTask: Task<Void, Never>?
  @ObservationIgnored private var reconnectTask: Task<Void, Never>?
  @ObservationIgnored private var listeningOn: DeviceIdentifier?

  init(wearables: WearablesInterface) {
    self.wearables = wearables
  }

  func start() {
    guard deviceTask == nil else { return }
    deviceTask = Task { [weak self] in
      guard let self else { return }
      await self.updateDevices(self.wearables.devices)
      for await identifiers in self.wearables.devicesStream() {
        await self.updateDevices(identifiers)
      }
    }
    registrationTask = Task { [weak self] in
      guard let self else { return }
      self.ensureListening()
      for await _ in self.wearables.registrationStateStream() {
        self.ensureListening()
      }
    }
  }

  func consumePendingLaunch() -> Bool {
    guard pendingLaunch else { return false }
    pendingLaunch = false
    return true
  }

  func requestVision() {
    pendingLaunch = true
  }

  private func updateDevices(_ identifiers: [DeviceIdentifier]) async {
    for token in linkTokens.values { await token.cancel() }
    linkTokens.removeAll()
    for identifier in identifiers {
      guard let device = wearables.deviceForIdentifier(identifier) else { continue }
      linkTokens[identifier] = device.addLinkStateListener { [weak self] _ in
        Task { @MainActor [weak self] in self?.ensureListening() }
      }
    }
    ensureListening()
  }

  private func ensureListening() {
    guard case .registered = wearables.registrationState else {
      if listeningOn != nil { stream?.stop() }
      listeningOn = nil
      status = "waiting for registration"
      return
    }
    if stream == nil {
      do {
        let newStream = try VoiceInvocationsStream(wearables: wearables)
        invocationToken = newStream.invocationsPublisher.listen { [weak self] invocation in
          guard let launch = invocation as? LaunchApp else { return }
          Task { @MainActor [weak self] in
            _ = await launch.responseHandle.sendSuccess(actionOutput: nil)
            self?.pendingLaunch = true
          }
        }
        errorToken = newStream.errorPublisher.listen { [weak self] _ in
          Task { @MainActor [weak self] in self?.scheduleReconnect() }
        }
        stream = newStream
      } catch {
        status = "voice channel unavailable"
        return
      }
    }
    guard listeningOn == nil else { return }
    for identifier in wearables.devices {
      do {
        try stream?.start(deviceIdentifier: identifier)
        listeningOn = identifier
        status = "voice ready"
        return
      } catch {
        status = "waiting for glasses link"
      }
    }
  }

  private func scheduleReconnect() {
    stream?.stop()
    listeningOn = nil
    status = "reconnecting voice"
    reconnectTask?.cancel()
    reconnectTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(700))
      guard !Task.isCancelled else { return }
      self?.ensureListening()
    }
  }
}

/// Local transport diagnostics for a physical phone without an Xcode console.
/// No serial numbers, credentials, frames, or audio are collected or uploaded.
/// An accessory count of zero is not conclusive: DAT also supports other links.
@MainActor
private struct ConnectionDiagnosticsView: View {
  let wearables: WearablesInterface
  @State private var showingReport = false
  @State private var report = ""
  @State private var copied = false

  private let accessoryProtocol = "com.meta.ar.wearable"

  private var buildLabel: String {
    Bundle.main.object(forInfoDictionaryKey: "CameraAccessDiagnosticBuild") as? String ?? "unmarked"
  }

  private var linkSummary: String {
    let states = wearables.devices.prefix(2).compactMap { id -> String? in
      guard let device = wearables.deviceForIdentifier(id) else { return nil }
      return String(describing: device.linkState)
    }
    return states.isEmpty ? "no device" : states.joined(separator: ", ")
  }

  private var accessoryCount: Int {
    EAAccessoryManager.shared().connectedAccessories.filter {
      $0.protocolStrings.contains(accessoryProtocol)
    }.count
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      Button {
        report = makeReport()
        copied = false
        showingReport = true
      } label: {
        VStack(alignment: .leading, spacing: 3) {
          Text("Диагностика \(buildLabel)")
            .fontWeight(.semibold)
          Text("DAT link: \(linkSummary)")
          Text("MFi accessories: \(accessoryCount)")
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain)
    }
    .sheet(isPresented: $showingReport) {
      NavigationStack {
        ScrollView {
          Text(report)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Диагностика \(buildLabel)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button("Обновить") {
              report = makeReport()
              copied = false
            }
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button("Готово") { showingReport = false }
          }
          ToolbarItem(placement: .bottomBar) {
            Button(copied ? "Скопировано" : "Копировать отчёт") {
              UIPasteboard.general.string = report
              copied = true
            }
          }
        }
      }
    }
  }

  private func makeReport() -> String {
    let info = Bundle.main.infoDictionary ?? [:]
    let modes = info["UIBackgroundModes"] as? [String] ?? []
    let protocols = info["UISupportedExternalAccessoryProtocols"] as? [String] ?? []
    let devices = wearables.devices
    var lines = [
      "Camera Access diagnostics: \(buildLabel)",
      "iOS: \(UIDevice.current.systemVersion)",
      "Registration: \(String(describing: wearables.registrationState))",
      "External-accessory mode: \(modes.contains("external-accessory"))",
      "Meta accessory protocol declared: \(protocols.contains(accessoryProtocol))",
      "Matching MFi accessories: \(accessoryCount)",
      "DAT devices: \(devices.count)",
    ]
    for (index, id) in devices.enumerated() {
      guard let device = wearables.deviceForIdentifier(id) else {
        lines.append("Device \(index + 1): unavailable during lookup")
        continue
      }
      lines.append("Device \(index + 1): link=\(String(describing: device.linkState))")
      lines.append("  compatibility=\(String(describing: device.compatibility()))")
    }
    lines.append("")
    lines.append("Session started does not prove that the camera link is ready.")
    lines.append("MFi count is only one transport signal; zero is not a diagnosis.")
    lines.append("This report stays on the phone unless you copy/share it.")
    return lines.joined(separator: "\n")
  }
}
