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
    private let storage: Storage<Base, Transformed>
    private var channelIterator: AsyncThrowingChannel<Transformed.Element, Error>.Iterator
    private let task: Task<Void, Never>

    init(
      base: Base,
      transform: @Sendable @escaping (Base.Element) async -> Transformed
    ) {
      let storage = Storage(base: base, transform: transform)
      self.storage = storage
      self.channelIterator = storage.channel.makeAsyncIterator()
      self.task = Task { await storage.run() }
    }

    public mutating func next() async throws -> Element? {
      try await withTaskCancellationHandler {
        try await channelIterator.next()
      } onCancel: { [task] in
        task.cancel()
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
private final class Storage<Base: AsyncSequence, Transformed: AsyncSequence>: Sendable
where Base: Sendable, Base.Element: Sendable, Transformed: Sendable, Transformed.Element: Sendable {
  fileprivate let channel = AsyncThrowingChannel<Transformed.Element, Error>()
  private let transform: @Sendable (Base.Element) async -> Transformed
  private let base: Base
  
  private let state = ManagedCriticalState(State.initial)

  private struct State {
    var innerTask: Task<Void, Never>?
    static var initial: State {
      State(innerTask: nil)
    }
  }

  init(
    base: Base,
    transform: @Sendable @escaping (Base.Element) async -> Transformed
  ) {
    self.base = base
    self.transform = transform
  }

  func run() async {
    do {
      var baseIterator = base.makeAsyncIterator()
      while let element = try await baseIterator.next() {
        if Task.isCancelled { break }
        
        let oldInnerTask = state.withCriticalRegion { state -> Task<Void, Never>? in
          let task = state.innerTask
          state.innerTask = nil
          return task
        }
        oldInnerTask?.cancel()

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
        state.withCriticalRegion { state in
          state.innerTask = newInnerTask
        }
      }
      
      let finalInnerTask = state.withCriticalRegion { state -> Task<Void, Never>? in
        let task = state.innerTask
        state.innerTask = nil
        return task
      }
      await finalInnerTask?.value
      channel.finish()
    } catch {
      channel.fail(error)
    }
  }
}