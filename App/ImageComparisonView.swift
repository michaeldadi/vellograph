import AppKit
import SwiftUI

struct ImageComparisonView: View {
    let left: URL
    let right: URL
    @State private var mode: Mode = .twoUp
    @State private var opacity = 0.5
    @State private var split = 0.5
    @State private var showingLeft = true

    enum Mode: String, CaseIterable {
        case twoUp = "Two Up", oneUp = "One Up", split = "Split", difference = "Difference"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 390)
                Spacer()
                if mode == .oneUp || mode == .difference {
                    Toggle("Show A", isOn: $showingLeft).toggleStyle(.switch)
                }
                if mode == .difference || mode == .split {
                    Slider(value: mode == .split ? $split : $opacity).frame(width: 150)
                }
            }.padding(12)
            Divider()
            GeometryReader { geometry in
                Group {
                    switch mode {
                    case .twoUp:
                        HStack(spacing: 2) {
                            picture(left)
                            picture(right)
                        }
                    case .oneUp:
                        picture(showingLeft ? left : right)
                    case .split:
                        ZStack {
                            picture(right)
                            picture(left)
                                .mask(alignment: .leading) {
                                    Rectangle().frame(width: geometry.size.width * split)
                                }
                        }
                    case .difference:
                        ZStack {
                            picture(showingLeft ? left : right)
                            picture(showingLeft ? right : left).opacity(opacity)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func picture(_ url: URL) -> some View {
        Group {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ContentUnavailableView("Cannot Open Image", systemImage: "photo.badge.exclamationmark")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

