//
//  Settings.swift
//  RoomyCore
//
//  Scan settings as plain data. The app persists them in UserDefaults, the CLI reads them
//  from flags and a JSON file. Neither persistence mechanism lives here.
//

import Foundation

public enum RoomyScanDefaultLocation: String, Codable, CaseIterable, Identifiable, Sendable {
    case home
    case custom
    case entireMac

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: return "Home folder (~/)"
        case .custom: return "Custom path"
        case .entireMac: return RoomyPlatform.current == .macOS ? "Entire Mac" : "Entire filesystem"
        }
    }
}

public struct RoomyAppSettings: Codable, Equatable, Sendable {
    public var defaultScanLocation: RoomyScanDefaultLocation
    public var customScanPath: String
    public var askBeforeEachScan: Bool
    /// Ecosystem keys: ai, npm, py, rust, ruby, go, java, swift, dotnet, general
    public var ecosystemsEnabled: [String: Bool]
    public var dormantThresholdYears: Int
    public var inactiveThresholdMonths: Int
    /// When true, use Trash; when false, permanent delete.
    public var moveToTrash: Bool
    public var emptyTrashAfterDeletion: Bool
    /// System cache categories, see `RoomySystemScanCategories`.
    public var systemScanEnabled: [String: Bool]

    enum CodingKeys: String, CodingKey {
        case defaultScanLocation, customScanPath, askBeforeEachScan, ecosystemsEnabled
        case dormantThresholdYears, inactiveThresholdMonths, moveToTrash, emptyTrashAfterDeletion
        case systemScanEnabled
    }

    public init(
        defaultScanLocation: RoomyScanDefaultLocation,
        customScanPath: String,
        askBeforeEachScan: Bool,
        ecosystemsEnabled: [String: Bool],
        dormantThresholdYears: Int,
        inactiveThresholdMonths: Int,
        moveToTrash: Bool,
        emptyTrashAfterDeletion: Bool,
        systemScanEnabled: [String: Bool]
    ) {
        self.defaultScanLocation = defaultScanLocation
        self.customScanPath = customScanPath
        self.askBeforeEachScan = askBeforeEachScan
        self.ecosystemsEnabled = ecosystemsEnabled
        self.dormantThresholdYears = dormantThresholdYears
        self.inactiveThresholdMonths = inactiveThresholdMonths
        self.moveToTrash = moveToTrash
        self.emptyTrashAfterDeletion = emptyTrashAfterDeletion
        self.systemScanEnabled = systemScanEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultScanLocation = try c.decode(RoomyScanDefaultLocation.self, forKey: .defaultScanLocation)
        customScanPath = try c.decode(String.self, forKey: .customScanPath)
        askBeforeEachScan = try c.decode(Bool.self, forKey: .askBeforeEachScan)
        ecosystemsEnabled = try c.decode([String: Bool].self, forKey: .ecosystemsEnabled)
        dormantThresholdYears = try c.decode(Int.self, forKey: .dormantThresholdYears)
        inactiveThresholdMonths = try c.decode(Int.self, forKey: .inactiveThresholdMonths)
        moveToTrash = try c.decode(Bool.self, forKey: .moveToTrash)
        emptyTrashAfterDeletion = try c.decode(Bool.self, forKey: .emptyTrashAfterDeletion)
        systemScanEnabled = try c.decodeIfPresent([String: Bool].self, forKey: .systemScanEnabled)
            ?? RoomySystemScanCategories.defaultEnabledMap()
    }

    public static let `default` = RoomyAppSettings(
        defaultScanLocation: .home,
        customScanPath: "",
        askBeforeEachScan: false,
        ecosystemsEnabled: Dictionary(uniqueKeysWithValues: RoomySettingsEcosystems.all.map { ($0.key, true) }),
        dormantThresholdYears: 2,
        inactiveThresholdMonths: 6,
        moveToTrash: true,
        emptyTrashAfterDeletion: false,
        systemScanEnabled: RoomySystemScanCategories.defaultEnabledMap()
    )

    /// Ecosystem keys still enabled for scanning.
    public var enabledEcosystemKeysForScan: Set<String> {
        Set(ecosystemsEnabled.compactMap { key, on in on ? key : nil })
    }

    public var enabledSystemScanKeys: Set<String> {
        Set(systemScanEnabled.compactMap { key, on in on ? key : nil })
    }
}

public struct RoomyEcosystemDescriptor: Sendable, Equatable {
    public let key: String
    public let name: String
    /// SF Symbol name. Strings only; the app maps them to images.
    public let icon: String
}

public enum RoomySettingsEcosystems {
    public static let all: [RoomyEcosystemDescriptor] = [
        .init(key: "ai", name: "AI tools / local models", icon: "sparkles"),
        .init(key: "npm", name: "Node.js / npm", icon: "cube.box"),
        .init(key: "py", name: "Python", icon: "doc.text"),
        .init(key: "rust", name: "Rust", icon: "gearshape.2"),
        .init(key: "ruby", name: "Ruby", icon: "diamond"),
        .init(key: "go", name: "Go", icon: "hare"),
        .init(key: "java", name: "Java / Kotlin", icon: "cup.and.saucer"),
        .init(key: "swift", name: "Swift / Xcode", icon: "swift"),
        .init(key: "dotnet", name: ".NET / NuGet", icon: "chevron.left.forwardslash.chevron.right"),
        .init(key: "general", name: "General (logs, .DS_Store, temp)", icon: "folder"),
    ]

    public static let allKeys: Set<String> = Set(all.map(\.key))
}

/// Synthetic project-root keys for system artifact groups in `artifactsByProjectRoot`.
public enum RoomySystemGroupRoot {
    public static let xcode = "__roomy:system:xcode__"
    public static let caches = "__roomy:system:caches__"
    public static let globalModules = "__roomy:system:global_modules__"
    public static let homebrew = "__roomy:system:homebrew__"
    public static let python = "__roomy:system:python__"
    public static let docker = "__roomy:system:docker__"
    public static let aiTools = "__roomy:system:ai_tools__"
    public static let agentHost = "__roomy:system:agent_host__"

    public static let allKeys: Set<String> = [xcode, caches, globalModules, homebrew, python, docker, aiTools, agentHost]

    /// Catalog category key -> group root key.
    public static func groupRoot(forCategory category: String) -> String {
        switch category {
        case "xcode": return xcode
        case "globalCaches": return caches
        case "globalModules": return globalModules
        case "homebrew": return homebrew
        case "python": return python
        case "docker": return docker
        case "aiTools": return aiTools
        case "agentHost": return agentHost
        default: return "__roomy:system:\(category)__"
        }
    }

    public static func category(forGroupRoot root: String) -> String? {
        switch root {
        case xcode: return "xcode"
        case caches: return "globalCaches"
        case globalModules: return "globalModules"
        case homebrew: return "homebrew"
        case python: return "python"
        case docker: return "docker"
        case aiTools: return "aiTools"
        case agentHost: return "agentHost"
        default:
            guard root.hasPrefix("__roomy:system:"), root.hasSuffix("__") else { return nil }
            return String(root.dropFirst("__roomy:system:".count).dropLast(2))
        }
    }

    public static func displayName(for rootKey: String) -> String {
        switch rootKey {
        case xcode: return "Xcode & iOS tooling"
        case caches: return "Global package caches"
        case globalModules: return "Global CLI packages"
        case homebrew: return "Homebrew"
        case python: return "Python tooling"
        case docker: return "Docker"
        case aiTools: return "AI coding tools"
        case agentHost: return "Agent host leftovers"
        default: return URL(fileURLWithPath: rootKey).lastPathComponent
        }
    }

    public static func isSystemRoot(_ path: String) -> Bool {
        path.hasPrefix("__roomy:system:")
    }
}

public struct RoomySystemScanCategory: Sendable, Equatable {
    public let key: String
    public let name: String
    public let detail: String
    /// Platforms where the category has anything to find.
    public let platforms: Set<RoomyPlatform>
}

public enum RoomySystemScanCategories {
    public static let all: [RoomySystemScanCategory] = [
        .init(key: "aiTools", name: "AI coding tools",
              detail: "Local models, Claude/Cursor/Codex caches, agent session history",
              platforms: [.macOS, .linux]),
        .init(key: "agentHost", name: "Agent host leftovers",
              detail: "OpenClaw logs and build captures, crash dumps, stale CLI versions, un-emptied trash",
              platforms: [.macOS, .linux]),
        .init(key: "xcode", name: "Xcode & iOS tooling",
              detail: "DerivedData, simulators, device support, archives",
              platforms: [.macOS]),
        .init(key: "globalCaches", name: "Global package caches",
              detail: "npm, pip, yarn, pnpm, NuGet, Poetry, uv, Go, Cargo, Gradle",
              platforms: [.macOS, .linux]),
        .init(key: "globalModules", name: "Global CLI packages",
              detail: "npm and yarn globally installed tools",
              platforms: [.macOS, .linux]),
        .init(key: "python", name: "Python / Conda",
              detail: "Conda unused packages, tarballs, dormant envs, pyenv",
              platforms: [.macOS, .linux]),
        .init(key: "homebrew", name: "Homebrew",
              detail: "Download caches and logs",
              platforms: [.macOS]),
        .init(key: "docker", name: "Docker",
              detail: "Unused images, volumes, build cache",
              platforms: [.macOS, .linux]),
    ]

    /// Categories that apply to the running platform.
    public static var available: [RoomySystemScanCategory] {
        all.filter { $0.platforms.contains(RoomyPlatform.current) }
    }

    public static func defaultEnabledMap() -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.key, true) })
    }

    public static let allKeys: Set<String> = Set(all.map(\.key))
}
