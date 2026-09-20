import Foundation

#if os(macOS)
import AppKit
import Virtualization

@main
struct AppleNano {
    static func main() {
        do {
            try CommandLineTool().run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            fputs("apple-nano: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}

private struct MachineMetadata: Codable {
    let hardwareModel: Data
    let machineIdentifier: Data
}

private enum NanoError: LocalizedError {
    case usage
    case missingOption(String)
    case invalidMachineDirectory(URL)

    var errorDescription: String? {
        switch self {
        case .usage:
            return """
            Usage:
              apple-nano prepare --restore-image <Tahoe.ipsw> --vm-directory <directory> [--disk-gb <size>]
              apple-nano install --restore-image <Tahoe.ipsw> --vm-directory <directory>
              apple-nano run --vm-directory <directory>

            Use an Apple-supplied macOS Tahoe restore image. This tool only runs on Apple hardware.
            """
        case .missingOption(let option): return "Missing required option \(option)."
        case .invalidMachineDirectory(let url): return "\(url.path) is not an Apple Nano virtual machine."
        }
    }
}

private final class CommandLineTool {
    private let fileManager = FileManager.default

    func run(arguments: [String]) throws {
        guard let command = arguments.first else { throw NanoError.usage }
        let options = try parseOptions(Array(arguments.dropFirst()))

        switch command {
        case "prepare": try prepare(options)
        case "install": try install(options)
        case "run": try runMachine(options)
        case "help", "--help", "-h": throw NanoError.usage
        default: throw NanoError.usage
        }
    }

    private func parseOptions(_ arguments: [String]) throws -> [String: String] {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard option.hasPrefix("--"), index + 1 < arguments.count else { throw NanoError.usage }
            options[option] = arguments[index + 1]
            index += 2
        }
        return options
    }

    private func requiredURL(_ option: String, from options: [String: String]) throws -> URL {
        guard let value = options[option], !value.isEmpty else { throw NanoError.missingOption(option) }
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    private func prepare(_ options: [String: String]) throws {
        let restoreURL = try requiredURL("--restore-image", from: options)
        let machineURL = try requiredURL("--vm-directory", from: options)
        guard !fileManager.fileExists(atPath: machineURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let diskGB = UInt64(options["--disk-gb"] ?? "64") ?? 64
        guard diskGB >= 32 else { throw CocoaError(.fileWriteInvalidFileName) }

        let restoreImage = try loadRestoreImage(at: restoreURL)
        let supported = restoreImage.mostFeaturefulSupportedConfiguration
        let hardwareModel = supported.hardwareModel
        let identifier = VZMacMachineIdentifier()

        try fileManager.createDirectory(at: machineURL, withIntermediateDirectories: true)
        try createEmptyDisk(at: machineURL.appendingPathComponent("disk.img"), size: diskGB * 1_073_741_824)
        _ = try VZMacAuxiliaryStorage(
            creatingStorageAt: machineURL.appendingPathComponent("auxiliary-storage"),
            hardwareModel: hardwareModel,
            options: []
        )
        let metadata = MachineMetadata(
            hardwareModel: hardwareModel.dataRepresentation,
            machineIdentifier: identifier.dataRepresentation
        )
        try JSONEncoder().encode(metadata).write(to: machineURL.appendingPathComponent("machine.json"), options: .atomic)

        print("Prepared \(machineURL.path). Install macOS Tahoe with the install command.")
    }

    private func install(_ options: [String: String]) throws {
        let restoreURL = try requiredURL("--restore-image", from: options)
        let machineURL = try requiredURL("--vm-directory", from: options)
        let metadata = try loadMetadata(machineURL)
        let restoreImage = try loadRestoreImage(at: restoreURL)
        guard restoreImage.mostFeaturefulSupportedConfiguration.hardwareModel.dataRepresentation == metadata.hardwareModel else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }

        let machine = VZVirtualMachine(configuration: try configuration(for: machineURL, metadata: metadata))
        let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: restoreURL)
        let result = DispatchSemaphore(value: 0)
        var installationError: Error?
        installer.install { error in
            installationError = error
            result.signal()
        }
        result.wait()
        if let installationError { throw installationError }
        print("macOS installation completed. Start it with: apple-nano run --vm-directory \(machineURL.path)")
    }

    private func runMachine(_ options: [String: String]) throws {
        let machineURL = try requiredURL("--vm-directory", from: options)
        let machine = VZVirtualMachine(configuration: try configuration(for: machineURL, metadata: try loadMetadata(machineURL)))
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let controller = MachineWindowController(machine: machine)
        application.delegate = controller
        controller.start()
        application.activate(ignoringOtherApps: true)
        application.run()
    }

    private func loadMetadata(_ machineURL: URL) throws -> MachineMetadata {
        let metadataURL = machineURL.appendingPathComponent("machine.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else { throw NanoError.invalidMachineDirectory(machineURL) }
        return try JSONDecoder().decode(MachineMetadata.self, from: Data(contentsOf: metadataURL))
    }

    private func configuration(for machineURL: URL, metadata: MachineMetadata) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = VZMacPlatformConfiguration()
        configuration.platform?.hardwareModel = VZMacHardwareModel(dataRepresentation: metadata.hardwareModel)!
        configuration.platform?.machineIdentifier = VZMacMachineIdentifier(dataRepresentation: metadata.machineIdentifier)!
        configuration.platform?.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: machineURL.appendingPathComponent("auxiliary-storage"))
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
        configuration.validate()
        return configuration
    }

    private func createEmptyDisk(at url: URL, size: UInt64) throws {
        guard fileManager.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        try handle.close()
    }

    private func loadRestoreImage(at url: URL) throws -> VZMacOSRestoreImage {
        let semaphore = DispatchSemaphore(value: 0)
        var image: VZMacOSRestoreImage?
        var loadError: Error?
        VZMacOSRestoreImage.load(from: url) { result in
            switch result {
            case .success(let loadedImage): image = loadedImage
            case .failure(let error): loadError = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let loadError { throw loadError }
        return image!
    }
}

private final class MachineWindowController: NSObject, NSApplicationDelegate, VZVirtualMachineDelegate {
    private let machine: VZVirtualMachine
    private let window: NSWindow

    init(machine: VZVirtualMachine) {
        self.machine = machine
        let view = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        view.virtualMachine = machine
        self.window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        machine.delegate = self
        window.title = "Apple Nano — macOS Tahoe"
        window.contentView = view
    }

    func start() {
        window.makeKeyAndOrderFront(nil)
        machine.start { error in
            if let error {
                NSAlert(error: error).runModal()
                NSApp.terminate(nil)
            }
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        NSAlert(error: error).runModal()
        NSApp.terminate(nil)
    }

    func virtualMachineDidStop(_ virtualMachine: VZVirtualMachine) {
        NSApp.terminate(nil)
    }
}

#else
@main
struct AppleNano {
    static func main() {
        fputs("apple-nano must be built and run on macOS on Apple hardware.\n", stderr)
    }
}
#endif
