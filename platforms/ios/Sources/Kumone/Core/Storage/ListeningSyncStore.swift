#if os(iOS)
import Combine
import Foundation
import OSLog

struct ListeningSyncSession: Equatable {
    let accountID: Int
    let revision: Int
}

@MainActor
final class ListeningSyncStore: ObservableObject {
    static let shared = ListeningSyncStore()

    @Published private(set) var summary = ListeningSyncQueue()
    @Published private(set) var storageFailed = false
    @Published private(set) var isSyncing = false

    private let files = ListeningSyncFiles(directory: URL.applicationSupportDirectory
        .appendingPathComponent("Kumone/ListeningSync", isDirectory: true))
    private let log = Logger(subsystem: "im.missuo.kumone", category: "listening-sync")
    private var session: ListeningSyncSession?
    private var queues: [Int: ListeningSyncQueue] = [:]
    private var blockedAccounts: Set<Int> = []
    private var verifiedCookies: NeteaseClient.ScopedCookies?
    private var worker: Task<Void, Never>?
    private var wakeup: Task<Void, Never>?

    // Legacy totals had no account owner. Leave their defaults intact and
    // start scoped counters without assigning those totals to a user.
    func activate(_ newSession: ListeningSyncSession?) {
        if session != newSession {
            session = newSession
            verifiedCookies = nil
            wakeup?.cancel()
            wakeup = nil
            if let accountID = newSession?.accountID { load(accountID) }
            publish()
        }
        schedule()
    }

    func enqueue(_ event: ListeningSyncEvent, accountID: Int) {
        load(accountID)
        guard var queue = queues[accountID], !queue.pending.contains(where: { $0.id == event.id }) else { return }
        queue.pending.append(event)
        if commit(queue, accountID: accountID) { schedule() }
    }

    func retryPending() {
        guard let accountID = session?.accountID, var queue = queues[accountID], worker == nil else { return }
        for index in queue.pending.indices where !queue.pending[index].inFlight {
            queue.pending[index].retryAfter = .distantPast
        }
        if commit(queue, accountID: accountID) { schedule() }
    }

    private func schedule() {
        wakeup?.cancel()
        wakeup = nil
        guard worker == nil, let session, !blockedAccounts.contains(session.accountID),
              let cookies = NeteaseClient.shared.scopedCookies(),
              let event = queues[session.accountID]?.pending.filter({ !$0.inFlight })
                .min(by: { $0.retryAfter < $1.retryAfter }) else { return }
        let delay = event.retryAfter.timeIntervalSinceNow
        if delay > 0 {
            // Bound the timer so a wall-clock change cannot postpone retries indefinitely.
            wakeup = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(min(delay, 900))) } catch { return }
                self?.schedule()
            }
            return
        }
        isSyncing = true
        worker = Task { [weak self] in
            guard let self else { return }
            await self.process(event, session: session, cookies: cookies)
            self.worker = nil
            self.isSyncing = false
            self.schedule()
        }
    }

    private func process(_ event: ListeningSyncEvent, session: ListeningSyncSession,
                         cookies: NeteaseClient.ScopedCookies) async {
        guard self.session == session else { return }
        let accountID = session.accountID
        do {
            if verifiedCookies != cookies {
                let owner = try await NeteaseAPI.userAccount(using: cookies)?.userId
                guard self.session == session else { return }
                guard owner == accountID else {
                    complete(event, accountID: accountID, result: .retryable)
                    return
                }
                verifiedCookies = cookies
                AccountStore.shared.rememberListeningAccount(accountID, using: cookies)
            }
            let trackID: Int?
            if let knownID = event.neteaseID ?? event.track.neteaseID {
                trackID = knownID
            } else {
                trackID = try await NeteaseAPI.matchListeningTrack(event.track, using: cookies)
            }
            guard self.session == session, NeteaseClient.shared.scopedCookies() == cookies,
                  var queue = queues[accountID],
                  let index = queue.pending.firstIndex(where: { $0.id == event.id }) else { return }
            guard let trackID else {
                queue.markUnmatched(event)
                _ = commit(queue, accountID: accountID)
                return
            }
            queue.pending[index].neteaseID = trackID
            queue.pending[index].inFlight = true
            guard commit(queue, accountID: accountID) else { return }
            let result = await NeteaseAPI.submitListening(event, trackID: trackID, using: cookies)
            if result == .retryable, self.session == session { verifiedCookies = nil }
            complete(event, accountID: accountID, result: result)
        } catch {
            // Verification and catalogue lookup are read-only, so all of
            // their errors are safe to retry.
            guard self.session == session else { return }
            complete(event, accountID: accountID, result: .retryable)
        }
    }

    private func complete(_ event: ListeningSyncEvent, accountID: Int, result: ListeningSubmissionResult) {
        guard var queue = queues[accountID] else { return }
        queue.complete(event, result: result, now: .now)
        _ = commit(queue, accountID: accountID)
    }

    private func load(_ accountID: Int) {
        guard queues[accountID] == nil, !blockedAccounts.contains(accountID) else { return }
        do {
            var queue = try files.load(accountID: accountID)
            if queue.pending.contains(where: \.inFlight) {
                queue.recoverInterruptedSubmissions()
                try files.save(queue, accountID: accountID)
            }
            queues[accountID] = queue
        } catch {
            blockedAccounts.insert(accountID)
            log.error("Unable to load listening sync queue")
        }
    }

    private func commit(_ queue: ListeningSyncQueue, accountID: Int) -> Bool {
        guard !blockedAccounts.contains(accountID) else { return false }
        do {
            try files.save(queue, accountID: accountID)
            queues[accountID] = queue
            publish()
            return true
        } catch {
            blockedAccounts.insert(accountID)
            log.error("Unable to save listening sync queue")
            publish()
            return false
        }
    }

    private func publish() {
        summary = session.flatMap { queues[$0.accountID] } ?? ListeningSyncQueue()
        storageFailed = session.map { blockedAccounts.contains($0.accountID) } ?? false
    }
}
#endif
