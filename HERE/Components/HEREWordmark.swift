import SwiftUI

struct HEREWordmark: View {
    let width: CGFloat

    var body: some View {
        Image("HereWordmark")
            .resizable()
            .scaledToFit()
            .frame(width: width, height: width)
            .frame(width: width, height: width * 0.5)
            .clipped()
            .accessibilityLabel("HERE")
    }
}
