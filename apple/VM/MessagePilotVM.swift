import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Virtualization

struct VMManifest: Codable {
  var hardwareModel: Data
  var machineIdentifier: Data
  var cpuCount: Int
  var memorySize: UInt64
  var installed: Bool
}
@MainActor final class VMController: ObservableObject {
  @Published var machine: VZVirtualMachine?
  @Published var status = "Choose an existing virtual Mac or create one."
  @Published var busy = false
  private var installer: VZMacOSInstaller?
  private var lockFile: Int32 = -1
  deinit {
    if lockFile >= 0 {
      flock(lockFile, LOCK_UN)
      close(lockFile)
    }
  }
  private func claim(_ folder: URL) throws {
    if lockFile >= 0 {
      flock(lockFile, LOCK_UN)
      close(lockFile)
      lockFile = -1
    }
    let fd = open(folder.appendingPathComponent("running.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      if fd >= 0 { close(fd) }
      throw failure("This virtual Mac is already open.")
    }
    lockFile = fd
  }
  private func failure(_ text: String) -> NSError {
    NSError(domain: "MessagePilot", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
  }
  func chooseOpen() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    Task { await openVM(folder) }
  }
  func chooseCreate() {
    let image = NSOpenPanel()
    image.title = "Choose a macOS 15 or newer IPSW"
    image.canChooseDirectories = false
    image.allowedContentTypes = [UTType(filenameExtension: "ipsw") ?? .data]
    guard image.runModal() == .OK, let restore = image.url else { return }
    let save = NSSavePanel()
    save.title = "Create a dedicated virtual Mac"
    save.nameFieldStringValue = "Agent.messagepilotvm"
    guard save.runModal() == .OK, let folder = save.url else { return }
    Task { await create(folder: folder, restore: restore) }
  }
  private func configuration(folder: URL, manifest: VMManifest) throws
    -> VZVirtualMachineConfiguration
  {
    guard let hardware = VZMacHardwareModel(dataRepresentation: manifest.hardwareModel),
      hardware.isSupported,
      let identifier = VZMacMachineIdentifier(dataRepresentation: manifest.machineIdentifier)
    else { throw failure("VM hardware is not supported on this host.") }
    let config = VZVirtualMachineConfiguration()
    config.cpuCount = manifest.cpuCount
    config.memorySize = manifest.memorySize
    config.bootLoader = VZMacOSBootLoader()
    let platform = VZMacPlatformConfiguration()
    platform.hardwareModel = hardware
    platform.machineIdentifier = identifier
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(
      contentsOf: folder.appendingPathComponent("AuxiliaryStorage"))
    config.platform = platform
    let disk = try VZDiskImageStorageDeviceAttachment(
      url: folder.appendingPathComponent("Disk.img"), readOnly: false)
    config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
    let graphics = VZMacGraphicsDeviceConfiguration()
    graphics.displays = [
      VZMacGraphicsDisplayConfiguration(
        widthInPixels: 1600, heightInPixels: 1000, pixelsPerInch: 110)
    ]
    config.graphicsDevices = [graphics]
    config.keyboards = [VZUSBKeyboardConfiguration()]
    config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    let network = VZVirtioNetworkDeviceConfiguration()
    network.attachment = VZNATNetworkDeviceAttachment()
    config.networkDevices = [network]
    let share = VZVirtioFileSystemDeviceConfiguration(tag: "MessagePilotShare")
    share.share = VZSingleDirectoryShare(
      directory: VZSharedDirectory(url: folder.appendingPathComponent("Shared"), readOnly: false))
    config.directorySharingDevices = [share]
    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    try config.validate()
    return config
  }
  private func create(folder: URL, restore: URL) async {
    guard !busy, machine?.state != .running else { return }
    busy = true
    defer { busy = false }
    do {
      guard !FileManager.default.fileExists(atPath: folder.path) else {
        throw failure("Choose a new folder; existing VM files are never overwritten.")
      }
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try claim(folder)
      try FileManager.default.createDirectory(
        at: folder.appendingPathComponent("Shared"), withIntermediateDirectories: true)
      status = "Reading restore image…"
      let image = try await VZMacOSRestoreImage.image(from: restore)
      guard let requirements = image.mostFeaturefulSupportedConfiguration else {
        throw failure("Restore image cannot run on this Mac.")
      }
      _ = try VZMacAuxiliaryStorage(
        creatingStorageAt: folder.appendingPathComponent("AuxiliaryStorage"),
        hardwareModel: requirements.hardwareModel, options: [])
      FileManager.default.createFile(
        atPath: folder.appendingPathComponent("Disk.img").path, contents: nil,
        attributes: [.posixPermissions: 0o600])
      let disk = try FileHandle(forWritingTo: folder.appendingPathComponent("Disk.img"))
      try disk.truncate(atOffset: 80 * 1024 * 1024 * 1024)
      try disk.close()
      var manifest = VMManifest(
        hardwareModel: requirements.hardwareModel.dataRepresentation,
        machineIdentifier: VZMacMachineIdentifier().dataRepresentation,
        cpuCount: max(
          requirements.minimumSupportedCPUCount,
          min(4, VZVirtualMachineConfiguration.maximumAllowedCPUCount)),
        memorySize: max(requirements.minimumSupportedMemorySize, 8 * 1024 * 1024 * 1024),
        installed: false)
      try JSONEncoder().encode(manifest).write(
        to: folder.appendingPathComponent("manifest.json"), options: .atomic)
      let vm = VZVirtualMachine(
        configuration: try configuration(folder: folder, manifest: manifest))
      machine = vm
      let install = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: restore)
      installer = install
      status = "Installing macOS into the dedicated disk…"
      try await install.install()
      manifest.installed = true
      try JSONEncoder().encode(manifest).write(
        to: folder.appendingPathComponent("manifest.json"), options: .atomic)
      installer = nil
      status = "Installed. Start and sign in with the agent’s Apple Account."
    } catch { status = error.localizedDescription }
  }
  private func openVM(_ folder: URL) async {
    guard !busy, machine?.state != .running else { return }
    busy = true
    defer { busy = false }
    do {
      try claim(folder)
      let manifest = try JSONDecoder().decode(
        VMManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
      guard manifest.installed else { throw failure("VM installation did not complete.") }
      machine = VZVirtualMachine(
        configuration: try configuration(folder: folder, manifest: manifest))
      status = "Ready."
    } catch { status = error.localizedDescription }
  }
  func start() {
    guard let machine, !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        try await machine.start()
        status = "Running. Use only this agent’s Apple Account."
      } catch { status = error.localizedDescription }
    }
  }
  func stop() {
    guard let machine else { return }
    do {
      try machine.requestStop()
      status = "Guest shutdown requested."
    } catch { status = error.localizedDescription }
  }
}
@main struct MessagePilotVMApp: App {
  @StateObject var controller = VMController()
  var body: some Scene {
    WindowGroup {
      VStack(spacing: 0) {
        HStack {
          Text("MessagePilot · Virtual Mac").font(.headline)
          Spacer()
          Button("Create", action: controller.chooseCreate)
          Button("Open", action: controller.chooseOpen)
          Button("Start", action: controller.start)
          Button("Shut down", action: controller.stop)
        }.padding().disabled(controller.busy)
        if let machine = controller.machine {
          VirtualDesktop(machine: machine)
        } else {
          ContentUnavailableView(
            "A computer for your agent", systemImage: "desktopcomputer",
            description: Text("Separate disk, desktop, Apple identity, and bridge worker."))
        }
        Text(controller.status).font(.caption).padding()
      }.frame(minWidth: 900, minHeight: 650)
    }
  }
}
struct VirtualDesktop: NSViewRepresentable {
  let machine: VZVirtualMachine
  func makeNSView(context: Context) -> VZVirtualMachineView {
    let view = VZVirtualMachineView()
    view.virtualMachine = machine
    view.capturesSystemKeys = true
    view.automaticallyReconfiguresDisplay = true
    return view
  }
  func updateNSView(_ view: VZVirtualMachineView, context: Context) {
    view.virtualMachine = machine
  }
}
