//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Async Algorithms open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension AsyncSequence {
  /// Transforms elements into new asynchronous sequences, emitting elements
  /// from the most recent inner sequence.
  ///
  /// When a new element is emitted by this sequence (the "outer" sequence),
  /// the `transform` is called to produce a new "inner" sequence. Iteration on the
  /// previous inner sequence is cancelled, and iteration begins on the new one.
  ///
  /// - Parameter transform: A closure that takes an element of this sequence and
  ///   returns a new asynchronous sequence.
  /// - Returns: An asynchronous sequence that emits elements from the latest
  ///   inner sequence.
  public func flatMapLatest<T: AsyncSequence>(
    _ transform: @Sendable @escaping (Element) async -> T
  ) -> AsyncFlatMapLatestSequence<Self, T> {
    AsyncFlatMapLatestSequence(self, transform: transform)
  }
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public struct AsyncFlatMapLatestSequence<Base: AsyncSequence, Transformed: AsyncSequence>: AsyncSequence
where Base: Sendable, Base.Element: Sendable, Transformed: Sendable, Transformed.Element: Sendable {
  public typealias Element = Transformed.Element

  let base: Base
  let transform: @Sendable (Base.Element) async -> Transformed

  init(
    _ base: Base,
    transform: @Sendable @escaping (Base.Element) async -> Transformed
  ) {
    self.base = base
    self.transform = transform
  }

  public struct Iterator: AsyncIteratorProtocol {
    private let coordinator: Coordinator<Base, Transformed>
    private var channelIterator: AsyncThrowingChannel<Transformed.Element, Error>.Iterator
    private var started = false

    init(
      base: Base,
      transform: @Sendable @escaping (Base.Element) async -> Transformed
    ) {
      let coordinator = Coordinator(base: base, transform: transform)
      self.coordinator = coordinator
      self.channelIterator = coordinator.channel.makeAsyncIterator()
    }

    public mutating func next() async throws -> Element? {
      let coordinator = self.coordinator
      if !started {
        started = true
        Task { await coordinator.start() }
      }
      return try await withTaskCancellationHandler {
        try await channelIterator.next()
      } onCancel: {
        Task { await coordinator.cancel() }
      }
    }
  }

  public func makeAsyncIterator() -> Iterator {
    Iterator(base: base, transform: transform)
  }
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension AsyncFlatMapLatestSequence: Sendable {}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
private actor Coordinator<Base: AsyncSequence, Transformed: AsyncSequence>
  where
    Base: Sendable,
    Base.Element: Sendable,
    Transformed: Sendable,
    Transformed.Element: Sendable
{
  private let base: Base
  private let transform: @Sendable (Base.Element) async -> Transformed
  let channel: AsyncThrowingChannel<Transformed.Element, Error>

  private var innerTask: Task<Void, Never>?

  init(
    base: Base,
    transform: @Sendable @escaping (Base.Element) async -> Transformed
  ) {
    self.base = base
    self.transform = transform
    self.channel = AsyncThrowingChannel<Transformed.Element, Error>()
  }

  func start() async {
    do {
      var baseIterator = base.makeAsyncIterator()
      while let element = try await baseIterator.next() {
        if Task.isCancelled { break }
        
        innerTask?.cancel()
        await Task.yield()

        let innerSequence = await transform(element)
        
        let newInnerTask = Task {
          do {
            var innerIterator = innerSequence.makeAsyncIterator()
            while let innerElement = try await innerIterator.next() {
              if Task.isCancelled { break }
              await channel.send(innerElement)
            }
          } catch {
            if !(error is CancellationError) {
              channel.fail(error)
            }
          }
        }
        innerTask = newInnerTask
      }
      
      await innerTask?.value
      channel.finish()
    } catch {
      channel.fail(error)
    }
  }

  func cancel() {
    innerTask?.cancel()
    channel.finish()
  }
}