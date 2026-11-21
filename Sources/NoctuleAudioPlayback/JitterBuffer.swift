// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

/// A fixed-capacity FIFO of 16-bit samples that smooths network jitter for playback.
///
/// `pull` returns silence until `prefillSamples` are buffered. If a pull finds fewer samples than
/// asked for, it serves what is left, pads with silence, counts an underrun, and waits to refill
/// to `prefillSamples` before playing again. When a push would exceed `capacitySamples`, the
/// oldest samples are dropped (and counted) to keep latency bounded.
public struct JitterBuffer: Sendable {
    public private(set) var underruns = 0
    public private(set) var overflowDroppedSamples = 0
    public private(set) var isPrimed = false

    /// Samples currently held.
    public var bufferedSamples: Int { count }

    private let capacity: Int
    private let prefill: Int
    private var storage: [Int16]
    private var head = 0
    private var count = 0

    public init(capacitySamples: Int = 8000, prefillSamples: Int = 1600) {
        capacity = max(1, capacitySamples)
        prefill = min(max(0, prefillSamples), capacity)
        storage = [Int16](repeating: 0, count: capacity)
    }

    public mutating func push(_ samples: [Int16]) {
        var input = samples[...]
        if input.count > capacity {
            let excess = input.count - capacity
            overflowDroppedSamples += excess + count
            input = input.dropFirst(excess)
            head = 0
            count = 0
        } else if count + input.count > capacity {
            let drop = count + input.count - capacity
            overflowDroppedSamples += drop
            head = (head + drop) % capacity
            count -= drop
        }
        var tail = (head + count) % capacity
        for sample in input {
            storage[tail] = sample
            tail += 1
            if tail == capacity { tail = 0 }
        }
        count += input.count
    }

    /// Marks the end of input: whatever is buffered is served even if below the prefill level.
    public mutating func finish() {
        if count > 0 { isPrimed = true }
    }

    /// Empties the buffer and returns to the unprimed state. Counters are kept.
    public mutating func reset() {
        head = 0
        count = 0
        isPrimed = false
    }

    public mutating func pull(_ count: Int) -> [Int16] {
        guard count > 0 else { return [] }
        return [Int16](unsafeUninitializedCapacity: count) { buffer, initialized in
            pull(into: buffer.baseAddress!, count: count)
            initialized = count
        }
    }

    /// Writes exactly `count` samples to `destination`. Does not allocate.
    public mutating func pull(into destination: UnsafeMutablePointer<Int16>, count requested: Int) {
        guard requested > 0 else { return }
        if !isPrimed, count >= prefill, count > 0 { isPrimed = true }
        var written = 0
        if isPrimed {
            let n = min(requested, count)
            for i in 0..<n {
                destination[i] = storage[head]
                head += 1
                if head == capacity { head = 0 }
            }
            count -= n
            written = n
            if n < requested {
                underruns += 1
                isPrimed = false
            }
        }
        for i in written..<requested { destination[i] = 0 }
    }
}
