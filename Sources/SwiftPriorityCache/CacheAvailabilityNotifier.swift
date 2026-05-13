import Combine

public struct CacheAvailabilityEvent: Sendable, Equatable {
    public let hash: String
    public let isAvailable: Bool
}

@MainActor
public class CacheAvailabilityNotifier {
    private let subject = PassthroughSubject<CacheAvailabilityEvent, Never>()
    public let publisher: AnyPublisher<CacheAvailabilityEvent, Never>

    public init() {
        publisher = subject.eraseToAnyPublisher()
    }

    func notify(events: [CacheAvailabilityEvent]) {
        for event in events {
            subject.send(event)
        }
    }
}
