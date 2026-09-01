import Foundation

/// A file or directory returned by an FFF filename search.
public struct FFFSearchResult: Equatable, Sendable {
    public let name: String
    public let relativePath: String
    public let url: URL
    public let isDirectory: Bool
    public let score: Int
    public let modified: UInt64
    public let size: UInt64

    public init(
        name: String,
        relativePath: String,
        url: URL,
        isDirectory: Bool,
        score: Int,
        modified: UInt64,
        size: UInt64
    ) {
        self.name = name
        self.relativePath = relativePath
        self.url = url
        self.isDirectory = isDirectory
        self.score = score
        self.modified = modified
        self.size = size
    }
}
/// A line of file content returned by an FFF content search.
public struct FFFContentMatch: Equatable, Sendable {
    public let name: String
    public let relativePath: String
    public let url: URL
    public let line: UInt64
    public let snippet: String

    public init(
        name: String,
        relativePath: String,
        url: URL,
        line: UInt64,
        snippet: String
    ) {
        self.name = name
        self.relativePath = relativePath
        self.url = url
        self.line = line
        self.snippet = snippet
    }
}

/// The current state of the asynchronous FFF scan and filesystem watcher.
public struct FFFIndexProgress: Equatable, Sendable {
    public let scannedFiles: UInt64
    public let isScanning: Bool
    public let isWatcherReady: Bool

    public init(scannedFiles: UInt64, isScanning: Bool, isWatcherReady: Bool) {
        self.scannedFiles = scannedFiles
        self.isScanning = isScanning
        self.isWatcherReady = isWatcherReady
    }
}
