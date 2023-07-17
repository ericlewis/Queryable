import SwiftUI

private struct QueryableAlertModifier<Item, Result, Actions: View, Message: View>: ViewModifier {
    @State private var ids: [UUID] = []

    @ObservedObject var queryable: Queryable<Item, Result>
    var title: String
    @ViewBuilder var actions: (_ item: Item, _ query: QueryResolver<Result>) -> Actions
    @ViewBuilder var message: (_ item: Item) -> Message

    func body(content: Content) -> some View {
        content
            .background {
                if let initialItemContainer = queryable.itemContainer {
                    ZStack {
                        StableItemContainerView(itemContainer: initialItemContainer) { itemContainer in
                            Color.clear
                                .alert(
                                    title,
                                    isPresented: .constant(true)
                                ) {
                                    actions(itemContainer.item, itemContainer.resolver)
                                } message: {
                                    message(itemContainer.item)
                                        .onDisappear {
                                            if let id = ids.first {
                                                queryable.autoCancelContinuation(id: id, reason: .presentationEnded)
                                                ids.removeFirst()
                                            }
                                        }
                                }
                        }
                        .onAppear { ids.append(initialItemContainer.id) }
                    }
                    .id(initialItemContainer.id)
                }
            }
    }
}

public extension View {

    /// Shows an alert controlled by a ``Queryable/Queryable``.
    @MainActor
    func queryableAlert<Item, Result, Actions: View, Message: View>(
        controlledBy queryable: Queryable<Item, Result>,
        title: String,
        @ViewBuilder actions: @escaping (_ item: Item, _ query: QueryResolver<Result>) -> Actions,
        @ViewBuilder message: @escaping (_ item: Item) -> Message
    ) -> some View {
        modifier(QueryableAlertModifier(queryable: queryable, title: title, actions: actions, message: message))
    }

    @MainActor
    func queryableAlert<Result, Actions: View, Message: View>(
        controlledBy queryable: Queryable<Void, Result>,
        title: String,
        @ViewBuilder actions: @escaping (_ query: QueryResolver<Result>) -> Actions,
        @ViewBuilder message: @escaping () -> Message
    ) -> some View {
        modifier(
            QueryableAlertModifier(queryable: queryable, title: title) { _, query in
                actions(query)
            } message: { _ in
                message()
            }
        )
    }
}
