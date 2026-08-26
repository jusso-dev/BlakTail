import SwiftUI

@MainActor
public struct RootView: View {
    @State private var model: PhoneModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: PhoneModel) {
        _model = State(initialValue: model)
    }

    public init() {
        self.init(model: PhoneModel())
    }

    public var body: some View {
        TabView {
            NavigationStack {
                ThisPhoneView(model: model)
            }
            .tabItem {
                Label("This iPhone", systemImage: "iphone")
            }
            NavigationStack {
                NetworkListView(model: model)
            }
            .tabItem {
                Label("Networks", systemImage: "point.3.connected.trianglepath.dotted")
            }
            NavigationStack {
                SettingsView(model: model)
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .environment(model)
        .onAppear { model.bootstrap() }
        .animation(reduceMotion ? nil : .default, value: model.isSignedIn)
    }
}
