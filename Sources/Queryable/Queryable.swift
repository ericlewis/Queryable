//
//  Copyright © 2023 Dennis Müller and all collaborators
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation
import Combine

/// A type that can trigger a view presentation from within an `async` function and `await` its completion and potential result value.
///
/// An example use case would be a boolean coming from a confirmation dialog view. First, create a property of the desired data type:
///
/// ```swift
/// @State var deletionConfirmation = Queryable<String, Bool>()
/// ```
///
/// Alternatively, you can put the queryable instance in any class that your view has access to:
///
/// ```swift
/// @Observable class SomeObservableObject {
///   var deletionConfirmation = Queryable<String, Bool>()
/// }
///
/// struct MyView: View {
///   @State private var someObservableObject = SomeObservableObject()
/// }
/// ```
///
/// Then, use one of the `queryable` prefixed presentation modifiers to show the deletion confirmation. For instance, here we use an alert:
///
/// ```swift
/// someView
///   .queryableAlert(
///     controlledBy: deletionConfirmation,
///     title: "Do you want to delete this?") { itemName, query in
///       Button("Cancel", role: .cancel) {
///         query.answer(with: false)
///       }
///       Button("OK") {
///         query.answer(with: true)
///       }
///     } message: { itemName in
///       Text("This cannot be reversed!")
///     }
/// ```
///
/// To actually present the alert and await the boolean result, call ``Queryable/Queryable/query(with:)`` on the ``Queryable/Queryable`` property.
/// This will activate the alert presentation which can then resolve the query in its completion handler.
///
/// ```swift
/// do {
///   let item = // ...
///   let shouldDelete = try await deletionConfirmation.query(with: item.name)
/// } catch {}
/// ```
///
/// When the Task that calls ``Queryable/Queryable/query(with:)`` is cancelled, the suspended query will also cancel and deactivate (i.e. close) the wrapped navigation presentation.
/// In that case, a ``Queryable/QueryCancellationError`` error is thrown.
@Observable @MainActor public final class Queryable<Input, Result> where Input: Sendable, Result: Sendable {
    let queryConflictPolicy: QueryConflictPolicy
    var storedContinuationState: ContinuationState?

    /// Optional item storing the input value for a query and is used to indicate if the query has started, which usually coincides with a presentation being shown.
    var itemContainer: ItemContainer?

    public init(queryConflictPolicy: QueryConflictPolicy = .cancelNewQuery) {
        self.queryConflictPolicy = queryConflictPolicy
    }

    // MARK: - Public Interface

    /// Requests the collection of data by starting a query on the `Result` type, providing an input value.
    ///
    /// This method will suspend for as long as the query is unanswered and not cancelled. When the parent Task is cancelled, this method will immediately cancel the query and throw a ``Queryable/QueryCancellationError`` error.
    ///
    /// Creating multiple queries at the same time will cause a query conflict which is resolved using the ``Queryable/QueryConflictPolicy`` defined in the initializer of ``Queryable/Queryable``. The default policy is ``Queryable/QueryConflictPolicy/cancelPreviousQuery``.
    /// - Returns: The result of the query.
    public func query(with item: Input) async throws -> Result {
        try await query(with: item, id: UUID().uuidString)
    }

    /// Requests the collection of data by starting a query on the `Result` type, providing an input value.
    ///
    /// This method will suspend for as long as the query is unanswered and not cancelled. When the parent Task is cancelled, this method will immediately cancel the query and throw a ``Queryable/QueryCancellationError`` error.
    ///
    /// Creating multiple queries at the same time will cause a query conflict which is resolved using the ``Queryable/QueryConflictPolicy`` defined in the initializer of ``Queryable/Queryable``. The default policy is ``Queryable/QueryConflictPolicy/cancelPreviousQuery``.
    /// - Returns: The result of the query.
    public func query() async throws -> Result where Input == Void {
        try await query(with: ())
    }

    /// Cancels any ongoing queries.
    public func cancel() {
        itemContainer?.resolver.answer(throwing: QueryCancellationError())
        itemContainer = nil
    }

    /// A flag indicating if a query is active.
    public var isQuerying: Bool {
        itemContainer != nil
    }
    
    /// An `AsyncStream` observing incoming queries and emitting their inputs and resolver to handle manually.
    ///
    /// Only use this, if you need more fine-grained control over the Queryable, i.e. setting view states yourself or adding tests.
    /// In most cases, you should prefer to use one of the `.queryable[...]` view modifiers instead.
    /// - Warning: With this, there will be no way of knowing when a query has been cancelled external
    /// (a sheet that was closed through a gesture, or a system dialog that has overridden any app dialogs)
    ///
    /// - Warning: Do not implement both a manual query observation as well as a `.queryable[...]` view modifier for the same Queryable instance.
    /// This will result in unexpected behavior.
    var queryObservation: AsyncStream<QueryObservation<Input, Result>> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self = self else { return }
                
                @MainActor
                func observe() async {
                    while !Task.isCancelled {
                        withObservationTracking {
                            _ = self.itemContainer
                        } onChange: {
                            Task { @MainActor in
                                if let container = self.itemContainer {
                                    continuation.yield(.init(queryId: container.id, input: container.item, resolver: container.resolver))
                                }
                                await observe()
                            }
                        }
                    }
                }
                
                await observe()
            }
            
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Internal Interface

    func query(with item: Input, id: String) async throws -> Result {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                storeContinuation(continuation, withId: id, item: item)
            }
        } onCancel: {
            Task {
                await autoCancelContinuation(id: id, reason: .taskCancelled)
            }
        }
    }

    func query(id: String) async throws -> Result where Input == Void {
        try await query(with: Void(), id: id)
    }

    func storeContinuation(
        _ newContinuation: CheckedContinuation<Result, Swift.Error>,
        withId id: String,
        item: Input
    ) {
        if let storedContinuationState {
            switch queryConflictPolicy {
            case .cancelPreviousQuery:
                logger.warning("Cancelling previous query of »\(Result.self, privacy: .public)« to allow new query.")
                storedContinuationState.continuation.resume(throwing: QueryCancellationError())
                self.storedContinuationState = nil
                self.itemContainer = nil
            case .cancelNewQuery:
                logger.warning("Cancelling new query of »\(Result.self, privacy: .public)« because another query is ongoing.")
                newContinuation.resume(throwing: QueryCancellationError())
                return
            }
        }

        let resolver = QueryResolver<Result> { result in
            self.resumeContinuation(returning: result, queryId: id)
        } errorHandler: {  error in
            self.resumeContinuation(throwing: error, queryId: id)
        }

        storedContinuationState = .init(queryId: id, continuation: newContinuation)
        itemContainer = .init(queryId: id, item: item, resolver: resolver)
    }

    func autoCancelContinuation(id: String, reason: AutoCancelReason) {
        // If the user cancels a query programmatically and immediately starts the next one, we need to prevent the `QueryInternalError.queryAutoCancel` from the `onDisappear` handler of the canceled query to cancel the new query. That's why the presentations store an id
        if storedContinuationState?.queryId == id {
            switch reason {
            case .presentationEnded:
                logger.notice("Cancelling query of »\(Result.self, privacy: .public)« because presentation has terminated.")
            case .taskCancelled:
                logger.notice("Cancelling query of »\(Result.self, privacy: .public)« because the task was cancelled.")
            }

            storedContinuationState?.continuation.resume(throwing: QueryCancellationError())
            storedContinuationState = nil
            itemContainer = nil
        }
    }

    // MARK: - Private Interface

    private func resumeContinuation(returning result: Result, queryId: String) {
        guard itemContainer?.id == queryId else { return }
        storedContinuationState?.continuation.resume(returning: result)
        storedContinuationState = nil
        itemContainer = nil
    }

    private func resumeContinuation(throwing error: Error, queryId: String) {
        guard itemContainer?.id == queryId else { return }
        storedContinuationState?.continuation.resume(throwing: error)
        storedContinuationState = nil
        itemContainer = nil
    }
}

// MARK: - Auxiliary Types

extension Queryable {
    struct ItemContainer: Identifiable {
        var id: String { queryId }
        let queryId: String
        var item: Input
        var resolver: QueryResolver<Result>
    }

    struct ContinuationState {
        let queryId: String
        var continuation: CheckedContinuation<Result, Swift.Error>
    }

    enum AutoCancelReason {
        case presentationEnded
        case taskCancelled
    }
}
