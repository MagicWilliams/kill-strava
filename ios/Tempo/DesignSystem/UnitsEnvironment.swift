import SwiftUI

extension EnvironmentValues {
    /// The athlete's mi/km preference (#109), set once at the root from `RunStore.units`.
    ///
    /// An environment value rather than `store.units` at each call site because most of
    /// what prints a distance is a row, a tile or a card that is handed its numbers and has
    /// no store: the 12-week card, the training wall, History's rows. It also reaches every
    /// sheet without each presenter remembering to pass it. The one place it does not reach
    /// on its own is an `ImageRenderer`, which starts a fresh environment (see the race
    /// recap's share card).
    @Entry var units: Units = .fallback
}
