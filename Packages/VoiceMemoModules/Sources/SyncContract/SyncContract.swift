import Foundation
import CryptoKit
import VoiceMemoDomain

public enum SyncKind: String, Codable, Sendable { case segment, manifest, storedReceipt, receiptQuery, missingReceipt, pendingReceipt, rejectedReceipt, deletedReceipt }
public enum SyncScope: String, Codable, Sendable { case segment, memo }
public enum SyncReasonCode: String, Codable, Sendable { case unsupportedSchema, invalidMetadata, hashMismatch, invalidAudio, idConflict, missing, pending, deleted, insufficientStorage }
public struct SyncEnvelope: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let kind: SyncKind
    public let eventID: UUID
    public let memoID: UUID
    public let segmentID: UUID?
    public let transferAttemptID: UUID?
    public let scope: SyncScope?
    public let digest: String?
    public let reasonCode: SyncReasonCode?
    public let metadata: [String: String]
    public init(kind: SyncKind, eventID: UUID = UUID(), memoID: UUID, segmentID: UUID? = nil, transferAttemptID: UUID? = nil, scope: SyncScope? = nil, digest: String? = nil, reasonCode: SyncReasonCode? = nil, metadata: [String: String] = [:], schemaVersion: Int = 2) { self.schemaVersion = schemaVersion; self.kind = kind; self.eventID = eventID; self.memoID = memoID; self.segmentID = segmentID; self.transferAttemptID = transferAttemptID; self.scope = scope; self.digest = digest; self.reasonCode = reasonCode; self.metadata = metadata }
    public func validate() throws {
        guard schemaVersion == 2 else { throw SyncError.unsupportedSchema }
        guard metadata.values.allSatisfy({ !$0.contains("\0") }) else { throw SyncError.invalidMetadata }
        switch kind {
        case .segment: guard segmentID != nil, transferAttemptID != nil else { throw SyncError.invalidMetadata }
        case .manifest: guard transferAttemptID != nil, digest?.count == 64 else { throw SyncError.invalidMetadata }
        case .storedReceipt, .receiptQuery: guard scope != nil, digest != nil else { throw SyncError.invalidMetadata }
        case .missingReceipt, .pendingReceipt, .rejectedReceipt: guard reasonCode != nil else { throw SyncError.invalidMetadata }
        case .deletedReceipt: guard scope == .memo else { throw SyncError.invalidMetadata }
        }
    }
}
public enum SyncError: Error, Sendable, Equatable { case unsupportedSchema, invalidMetadata, hashMismatch, invalidAudio, idConflict }
public struct ManifestFile: Codable, Sendable, Equatable {
    public let descriptor: RecordingDescriptor
    public let manifestHash: String
    public init(descriptor: RecordingDescriptor) throws {
        self.descriptor = descriptor
        self.manifestHash = SHA256.hash(data: descriptor.manifestHashInput).compactMap { String(format: "%02x", $0) }.joined()
    }
    public func validate() throws {
        try descriptor.validate()
        guard manifestHash.count == 64 else { throw SyncError.hashMismatch }
    }
}
public enum SyncContractCodec { public static func encode(_ envelope: SyncEnvelope) throws -> Data { try envelope.validate(); return try JSONEncoder.voiceMemo.encode(envelope) }; public static func decode(_ data: Data) throws -> SyncEnvelope { let value = try JSONDecoder.voiceMemo.decode(SyncEnvelope.self, from: data); try value.validate(); return value } }
