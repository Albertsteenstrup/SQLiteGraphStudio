import Foundation
import Observation

@MainActor @Observable
public final class RecordWorkspace {
    public typealias Loader = @Sendable (RecordSnapshot, RecordRelationship, RecordDirection, Int, Int) async throws -> RecordPage
    public typealias MappingLoader = @Sendable (RecordGraphMapping, RecordSnapshot, RecordDirection, Int, CatalogSnapshot) async throws -> RecordMappedPage
    public var mappings: [RecordGraphMapping] = []
    public var mappingValidationMessages: [String] = []
    public var catalog = CatalogSnapshot(descriptors: [], graph: .empty)
    public private(set) var mappedPages: [RecordExpansionKey: RecordMappedPage] = [:]
    public var isPresented = false
    public var showsGraph = false
    public var originLabel = "Table or query"
    public var relationships: [RecordRelationship] = []
    public private(set) var history: [RecordSnapshot] = []
    public private(set) var cursor = -1
    public private(set) var pages: [RecordExpansionKey: RecordPage] = [:]
    public private(set) var offsets: [RecordExpansionKey: Int] = [:]
    public private(set) var errors: [RecordExpansionKey: String] = [:]
    public private(set) var loading: Set<RecordExpansionKey> = []
    public var notice: String?
    public let recordGraph = RecordGraphModel()
    private let loader: Loader
    private let mappingLoader: MappingLoader?
    private var generation = UUID()
    private var requests: [RecordExpansionKey: Task<Void, Never>] = [:]

    public init(mappingLoader: MappingLoader? = nil, loader: @escaping Loader) { self.loader = loader; self.mappingLoader = mappingLoader }
    public var current: RecordSnapshot? { history.indices.contains(cursor) ? history[cursor] : nil }
    public var canGoBack: Bool { cursor >= 0 }
    public var canGoForward: Bool { cursor + 1 < history.count }

    public func open(_ record: RecordSnapshot) {
        reset(); history = [record]; cursor = 0; isPresented = true
    }
    public func navigate(_ record: RecordSnapshot) {
        cancel(); history = Array(history.prefix(cursor + 1)); history.append(record)
        cursor = history.count - 1; isPresented = true
    }
    public func back() {
        guard canGoBack else { return }; cancel(); cursor -= 1
        if cursor < 0 { isPresented = false }
    }
    public func forward() {
        guard canGoForward else { return }; cancel(); cursor += 1; isPresented = true
    }
    public func showConnections() {
        guard let current, current.identity != nil else { return }
        cancel(); recordGraph.setRoot(current); showsGraph = true
    }
    public func reset() {
        cancel(); history = []; cursor = -1; pages = [:]; mappedPages = [:]; offsets = [:]; errors = [:]
        recordGraph.setRoot(nil); showsGraph = false; isPresented = false; notice = nil
    }
    public func cancel() {
        generation = UUID(); requests.values.forEach { $0.cancel() }
        requests = [:]; loading = []
    }
    public func key(_ relationship: RecordRelationship, _ direction: RecordDirection) -> RecordExpansionKey? {
        current.map { .init(recordID: $0.id, relationshipID: relationship.id, direction: direction) }
    }

    @discardableResult
    public func loadMapping(_ mapping: RecordGraphMapping, direction: RecordDirection, offset: Int = 0, intoGraph: Bool = false) -> Task<Void, Never>? {
        guard let current, let mappingLoader else { return nil }
        let key = RecordExpansionKey(recordID: current.id, relationshipID: "mapping:" + mapping.id, direction: direction)
        guard !loading.contains(key), loading.count < 2 else {
            notice = "Two relationship requests are already running. Wait or cancel before expanding another."; return nil
        }
        if intoGraph && !recordGraph.beginExpansion(from: current, cost: 7) { return nil }
        let token = generation, catalog = catalog
        loading.insert(key); errors[key] = nil; notice = nil
        let task = Task { [weak self] in
            do {
                let page = try await mappingLoader(mapping, current, direction, offset, catalog)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.mappedPages[key] = page; self.offsets[key] = offset
                if intoGraph { self.recordGraph.addMapped(page, from: current, mappingID: mapping.id, direction: direction, offset: offset) }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.errors[key] = error.localizedDescription
            }
            guard let self, self.generation == token else { return }
            self.loading.remove(key); self.requests[key] = nil
        }
        requests[key] = task
        return task
    }

    @discardableResult
    public func load(_ relationship: RecordRelationship, direction: RecordDirection, offset: Int = 0, intoGraph: Bool = false) -> Task<Void, Never>? {
        guard let current, let key = key(relationship, direction) else { return nil }
        guard !loading.contains(key), loading.count < 2 else {
            notice = "Two relationship requests are already running. Wait or cancel before expanding another."; return nil
        }
        if intoGraph && !recordGraph.beginExpansion(from: current) { return nil }
        let token = generation
        loading.insert(key); errors[key] = nil; notice = nil
        let task = Task { [weak self, loader] in
            do {
                let page = try await loader(current, relationship, direction, max(0, offset), 25)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.pages[key] = page; self.offsets[key] = offset
                if intoGraph { self.recordGraph.add(page, from: current, relationship: relationship, direction: direction, offset: offset) }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.errors[key] = error.localizedDescription
            }
            guard let self, self.generation == token else { return }
            self.loading.remove(key); self.requests[key] = nil
        }
        requests[key] = task
        return task
    }
}
