import Foundation

#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Virtualization

@main
struct AppleNanoApp: App {
    var body: some Scene {
        WindowGroup("Apple Nano") {
            ControlPanelView()
        }
        .defaultSize(width: 760, height: 560)
    }
}

private enum MacOSVersion: String, CaseIterable, Identifiable {
    case tahoe = "macOS Tahoe"
    case sequoia = "macOS Sequoia"
    case sonoma = "macOS Sonoma"

    var id: String { rawValue }
}

private struct MachineMetadata: Codable {
    let hardwareModel: Data
    let machineIdentifier: Data
    let versionName: String
}

private enum NanoError: LocalizedError {
    case missingRestoreImage
    case missingMachineFolder
    case invalidMachineDirectory(URL)
    case existingMachine(URL)
    case unsupportedDiskSize

    var errorDescription: String? {
        switch self {
        case .missingRestoreImage: return "Виберіть офіційний Apple restore image (.ipsw)."
        case .missingMachineFolder: return "Виберіть порожню папку для віртуальної машини."
        case .invalidMachineDirectory(let url): return "\(url.path) не є віртуальною машиною Apple Nano."
        case .existingMachine(let url): return "Папка \(url.path) уже існує. Виберіть нову порожню папку."
        case .unsupportedDiskSize: return "Диск ВМ має бути не менше 32 ГБ."
        }
    }
}

@MainActor
private final class VMSetupModel: ObservableObject {
    @Published var selectedVersion: MacOSVersion = .tahoe
    @Published var restoreImageURL: URL?
    @Published var machineURL: URL?
    @Published var diskGB = 64
    @Published var status = "Виберіть версію macOS, IPSW і папку для ВМ."
    @Published var isWorking = false
    @Published var errorMessage: String?

    private var runningMachine: MachineWindowController?

    func prepare() {
        perform("Підготовка віртуального Mac…") {
            guard let restoreImageURL else { throw NanoError.missingRestoreImage }
            guard let machineURL else { throw NanoError.missingMachineFolder }
            try await VirtualMachineService.prepare(
                restoreImageURL: restoreImageURL,
                machineURL: machineURL,
                diskGB: diskGB,
                versionName: selectedVersion.rawValue
            )
            return "ВМ підготовлена. Натисніть «Встановити macOS»."
        }
    }

    func install() {
        perform("Встановлення macOS може тривати кілька хвилин…") {
            guard let restoreImageURL else { throw NanoError.missingRestoreImage }
            guard let machineURL else { throw NanoError.missingMachineFolder }
            try await VirtualMachineService.install(restoreImageURL: restoreImageURL, machineURL: machineURL)
            return "macOS встановлено. ВМ готова до запуску."
        }
    }

    func run() {
        do {
            guard let machineURL else { throw NanoError.missingMachineFolder }
            runningMachine = try VirtualMachineService.makeWindowController(machineURL: machineURL)
            runningMachine?.start()
            status = "Віртуальна машина запущена у новому вікні."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openSimulator() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Simulator"]
        do {
            try task.run()
            status = "Відкрито Xcode Simulator для iPhone та iPad."
        } catch {
            errorMessage = "Не вдалося відкрити Simulator. Встановіть Xcode: \(error.localizedDescription)"
        }
    }

    private func perform(_ workingStatus: String, operation: @escaping () async throws -> String) {
        isWorking = true
        errorMessage = nil
        status = workingStatus
        Task {
            do {
                status = try await operation()
            } catch {
                errorMessage = error.localizedDescription
                status = "Операцію не завершено."
            }
            isWorking = false
        }
    }
}

private struct ControlPanelView: View {
    @StateObject private var model = VMSetupModel()
    @State private var isImportingImage = false
    @State private var isChoosingFolder = false

    var body: some View {
        TabView {
            macVirtualMachineTab
                .tabItem { Label("Віртуальний Mac", systemImage: "desktopcomputer") }
            mobileSimulatorTab
                .tabItem { Label("iPhone та iPad", systemImage: "iphone") }
        }
        .padding()
        .fileImporter(isPresented: $isImportingImage, allowedContentTypes: [UTType(filenameExtension: "ipsw")!]) { result in
            if case .success(let url) = result { model.restoreImageURL = url }
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.machineURL = url }
        }
        .alert("Помилка", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Гаразд", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var macVirtualMachineTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Налаштування віртуального Mac")
                .font(.title2.bold())
            Text("Створіть і запускайте справжню macOS на Apple Silicon Mac.")
                .foregroundStyle(.secondary)

            Form {
                Picker("Версія macOS", selection: $model.selectedVersion) {
                    ForEach(MacOSVersion.allCases) { version in Text(version.rawValue).tag(version) }
                }
                HStack {
                    Text("Restore image")
                    Spacer()
                    Text(model.restoreImageURL?.lastPathComponent ?? "Не вибрано").lineLimit(1).foregroundStyle(.secondary)
                    Button("Вибрати IPSW") { isImportingImage = true }
                }
                HStack {
                    Text("Папка ВМ")
                    Spacer()
                    Text(model.machineURL?.path ?? "Не вибрано").lineLimit(1).foregroundStyle(.secondary)
                    Button("Вибрати папку") { isChoosingFolder = true }
                }
                Stepper("Розмір диска: \(model.diskGB) ГБ", value: $model.diskGB, in: 32...512, step: 8)
            }

            HStack {
                Button("1. Підготувати") { model.prepare() }
                Button("2. Встановити macOS") { model.install() }
                    .disabled(model.machineURL == nil || model.restoreImageURL == nil)
                Button("Запустити ВМ") { model.run() }
                    .disabled(model.machineURL == nil)
            }
            .disabled(model.isWorking)

            ProgressView().opacity(model.isWorking ? 1 : 0)
            Text(model.status).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var mobileSimulatorTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("iPhone та iPad")
                .font(.title2.bold())
            Text("Для запуску програм iPhone та iPad використовуйте Xcode Simulator.")
                .foregroundStyle(.secondary)
            Button("Відкрити Xcode Simulator") { model.openSimulator() }
                .buttonStyle(.borderedProminent)
            Divider()
            Text("Apple Nano не може запускати macOS-віртуальну машину на iPhone або iPad: Apple Virtualization доступний лише на Mac. Xcode Simulator — підтримуваний Apple спосіб тестувати iOS та iPadOS на Mac.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}

private enum VirtualMachineService {
    static func prepare(restoreImageURL: URL, machineURL: URL, diskGB: Int, versionName: String) async throws {
        guard diskGB >= 32 else { throw NanoError.unsupportedDiskSize }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: machineURL.path) else { throw NanoError.existingMachine(machineURL) }
        let restoreImage = try await loadRestoreImage(at: restoreImageURL)
        let hardwareModel = restoreImage.mostFeaturefulSupportedConfiguration.hardwareModel
        let identifier = VZMacMachineIdentifier()
        try fileManager.createDirectory(at: machineURL, withIntermediateDirectories: true)
        try createEmptyDisk(at: machineURL.appendingPathComponent("disk.img"), size: UInt64(diskGB) * 1_073_741_824)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: machineURL.appendingPathComponent("auxiliary-storage"), hardwareModel: hardwareModel, options: [])
        let metadata = MachineMetadata(hardwareModel: hardwareModel.dataRepresentation, machineIdentifier: identifier.dataRepresentation, versionName: versionName)
        try JSONEncoder().encode(metadata).write(to: machineURL.appendingPathComponent("machine.json"), options: .atomic)
    }

    static func install(restoreImageURL: URL, machineURL: URL) async throws {
        let metadata = try loadMetadata(machineURL)
        let restoreImage = try await loadRestoreImage(at: restoreImageURL)
        guard restoreImage.mostFeaturefulSupportedConfiguration.hardwareModel.dataRepresentation == metadata.hardwareModel else {
            throw NanoError.invalidMachineDirectory(machineURL)
        }
        let machine = VZVirtualMachine(configuration: try configuration(machineURL: machineURL, metadata: metadata))
        let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: restoreImageURL)
        try await withCheckedThrowingContinuation { continuation in
            installer.install { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    static func makeWindowController(machineURL: URL) throws -> MachineWindowController {
        let machine = VZVirtualMachine(configuration: try configuration(machineURL: machineURL, metadata: loadMetadata(machineURL)))
        return MachineWindowController(machine: machine)
    }

    private static func configuration(machineURL: URL, metadata: MachineMetadata) throws -> VZVirtualMachineConfiguration {
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: metadata.hardwareModel), let identifier = VZMacMachineIdentifier(dataRepresentation: metadata.machineIdentifier) else {
            throw NanoError.invalidMachineDirectory(machineURL)
        }
        let configuration = VZVirtualMachineConfiguration()
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = try VZMacAuxiliaryStorage(contentsOf: machineURL.appendingPathComponent("auxiliary-storage"))
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = min(max(VZVirtualMachineConfiguration.minimumAllowedCPUCount, 4), VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        configuration.memorySize = max(8 * 1_073_741_824, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
        let disk = try VZDiskImageStorageDeviceAttachment(url: machineURL.appendingPathComponent("disk.img"), readOnly: false)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = [network]
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1080, pixelsPerInch: 220)]
        configuration.graphicsDevices = [graphics]
        try configuration.validate()
        return configuration
    }

    private static func loadMetadata(_ machineURL: URL) throws -> MachineMetadata {
        let url = machineURL.appendingPathComponent("machine.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw NanoError.invalidMachineDirectory(machineURL) }
        return try JSONDecoder().decode(MachineMetadata.self, from: Data(contentsOf: url))
    }

    private static func createEmptyDisk(at url: URL, size: UInt64) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        try handle.close()
    }

    private static func loadRestoreImage(at url: URL) async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.load(from: url) { result in
                continuation.resume(with: result)
            }
        }
    }
}

private final class MachineWindowController: NSObject, VZVirtualMachineDelegate {
    private let machine: VZVirtualMachine
    private let window: NSWindow

    init(machine: VZVirtualMachine) {
        self.machine = machine
        let view = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        view.virtualMachine = machine
        self.window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        machine.delegate = self
        window.title = "Apple Nano — macOS"
        window.contentView = view
    }

    func start() {
        window.makeKeyAndOrderFront(nil)
        machine.start { error in
            if let error { NSAlert(error: error).runModal() }
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        NSAlert(error: error).runModal()
    }
}

#else
@main
struct AppleNanoApp {
    static func main() {
        fputs("Apple Nano requires macOS on Apple hardware.\n", stderr)
    }
}
#endif
