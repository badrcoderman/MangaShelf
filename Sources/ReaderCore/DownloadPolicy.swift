import Foundation

/// Pure policy shared by the queue and deterministic tests. No requests or sleeps happen here.
public enum DownloadPolicy {
    public static let maximumRetries = 3

    public static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value, value.utf8.count <= 128 else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(text), seconds.isFinite, seconds >= 0, seconds <= 3_153_600_000 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: text) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    public static func nextRetry(error: Error, retryCount: Int, now: Date) -> Date? {
        guard retryCount < maximumRetries, !(error is CancellationError) else { return nil }
        var status: Int?, retryAfter: TimeInterval?
        var network = false
        if let failure = error as? SourceRequestFailure {
            status = failure.httpStatus; retryAfter = failure.retryAfterSeconds
            network = failure.reason == .network || failure.reason == .timeout || failure.reason == .imageTransferLimit
        } else if let failure = error as? SourceHTTPFailure {
            status = failure.statusCode; retryAfter = failure.retryAfterSeconds
        } else {
            let failure = error as NSError
            network = failure.domain == NSURLErrorDomain && [
                NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet
            ].contains(failure.code)
        }
        guard network || status == 429 || status == 408 || status == 425 || status.map({ (500...599).contains($0) }) == true else { return nil }
        let backoff = (status == 429 ? 30.0 : 2.0) * pow(2.0, Double(max(0, retryCount)))
        return now.addingTimeInterval(max(backoff, retryAfter ?? 0))
    }

    /// A source in Retry-After cools down as a whole, including other queued chapters.
    public static func runnable(_ jobs: [ChapterDownload], activeIDs: Set<String>,
                                sourceIDs: [String: String], maximumConcurrent: Int = 4,
                                perSource: Int = 1, now: Date) -> [ChapterDownload] {
        let slots = max(0, min(4, maximumConcurrent) - activeIDs.count)
        guard slots > 0 else { return [] }
        var counts: [String: Int] = [:], cooldowns: [String: Date] = [:]
        for job in jobs {
            let source = sourceIDs[job.chapter.seriesID] ?? job.chapter.seriesID
            if activeIDs.contains(job.id) { counts[source, default: 0] += 1 }
            if let retry = job.nextRetryAt, retry > now {
                cooldowns[source] = max(cooldowns[source] ?? .distantPast, retry)
            }
        }
        var result: [ChapterDownload] = []
        for job in jobs where (job.phase == .queued || job.phase == .retrying) && !activeIDs.contains(job.id) {
            let source = sourceIDs[job.chapter.seriesID] ?? job.chapter.seriesID
            guard cooldowns[source] == nil, (job.nextRetryAt ?? .distantPast) <= now,
                  counts[source, default: 0] < max(1, min(3, perSource)) else { continue }
            result.append(job); counts[source, default: 0] += 1
            if result.count == slots { break }
        }
        return result
    }
}
