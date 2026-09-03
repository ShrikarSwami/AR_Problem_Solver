import SwiftUI
import MWDATCore

@main
struct AR_Problem_SolverApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { url in
                    model.handle(url: url)
                }
        }
    }
}
