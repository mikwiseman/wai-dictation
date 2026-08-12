import SwiftUI

/// Главная кнопка экрана: стеклянная на macOS 26, обычная выделенная — раньше.
///
/// Liquid Glass положен ровно самым важным элементам управления — по одной
/// главной кнопке на окно. Содержимое экранов остаётся без стекла: это слой
/// управления, а не украшение.
extension View {
    @ViewBuilder
    func prominentActionButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}
