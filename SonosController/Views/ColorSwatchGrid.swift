/// ColorSwatchGrid.swift — Compact color swatch picker with preset colors and a custom picker.
///
/// Displays presets in two rows of 8. When system is allowed, it takes the first slot.
/// The macOS ColorPicker appears as a double-wide button at the end of the second row.
import SwiftUI
import SonosKit

struct ColorSwatchGrid: View {
    @Binding var storedColor: StoredColor
    let allowSystem: Bool

    @State private var pickerColor: Color = .blue

    private static let presets: [(String, Color, StoredColor)] = [
        ("Blue",   .blue,   StoredColor(red: 0.0,  green: 0.48, blue: 1.0)),
        ("Purple", .purple, StoredColor(red: 0.69, green: 0.32, blue: 0.87)),
        ("Pink",   .pink,   StoredColor(red: 1.0,  green: 0.18, blue: 0.33)),
        ("Red",    .red,    StoredColor(red: 1.0,  green: 0.23, blue: 0.19)),
        ("Orange", .orange, StoredColor(red: 1.0,  green: 0.58, blue: 0.0)),
        ("Yellow", .yellow, StoredColor(red: 1.0,  green: 0.84, blue: 0.0)),
        ("Green",  .green,  StoredColor(red: 0.2,  green: 0.78, blue: 0.35)),
        ("Teal",   .teal,   StoredColor(red: 0.19, green: 0.69, blue: 0.78)),
        ("Cyan",   .cyan,   StoredColor(red: 0.39, green: 0.82, blue: 1.0)),
        ("Indigo", .indigo, StoredColor(red: 0.35, green: 0.34, blue: 0.84)),
        ("Mint",   .mint,   StoredColor(red: 0.0,  green: 0.78, blue: 0.75)),
        ("White",  .white,  StoredColor(red: 1.0,  green: 1.0,  blue: 1.0)),
        ("Gray",   .gray,   StoredColor(red: 0.56, green: 0.56, blue: 0.58)),
        ("Black",  Color(white: 0.15), StoredColor(red: 0.15, green: 0.15, blue: 0.15)),
    ]

    // With system: [System, 7 presets] + [7 presets, Custom] = 2 rows of 8
    // Without system: [8 presets] + [6 presets, Custom(double)] = 2 rows of 8

    private var row1: [(String, AnyView, StoredColor?)] {
        var items: [(String, AnyView, StoredColor?)] = []
        let presets = Self.presets

        if allowSystem {
            items.append(("System", AnyView(systemSwatch), nil))
            for i in 0..<7 { items.append(presetItem(presets[i])) }
        } else {
            for i in 0..<8 { items.append(presetItem(presets[i])) }
        }
        return items
    }

    private var row2Count: Int {
        // How many preset swatches on row 2 (before the custom picker)
        allowSystem ? 7 : 6
    }

    private var row2: [(String, AnyView, StoredColor?)] {
        var items: [(String, AnyView, StoredColor?)] = []
        let presets = Self.presets
        let startIdx = allowSystem ? 7 : 8

        for i in startIdx..<min(startIdx + row2Count, presets.count) {
            items.append(presetItem(presets[i]))
        }
        return items
    }

    private var systemSwatch: some View {
        Circle().fill(AngularGradient(
            colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red],
            center: .center
        ))
    }

    private func presetItem(_ preset: (String, Color, StoredColor)) -> (String, AnyView, StoredColor?) {
        (preset.0, AnyView(Circle().fill(preset.1)), preset.2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Row 1
            HStack(spacing: 4) {
                ForEach(row1, id: \.0) { name, view, stored in
                    swatchButton(
                        isSelected: stored == nil ? storedColor.isSystem : (!storedColor.isSystem && isMatch(stored!)),
                        content: view,
                        help: name
                    ) {
                        if let s = stored { storedColor = s } else { storedColor = .system }
                    }
                }
            }

            // Row 2 + Custom picker
            HStack(spacing: 4) {
                ForEach(row2, id: \.0) { name, view, stored in
                    swatchButton(
                        isSelected: stored != nil && !storedColor.isSystem && isMatch(stored!),
                        content: view,
                        help: name
                    ) {
                        if let s = stored { storedColor = s }
                    }
                }

                // Custom color picker — double-wide
                customPickerButton
            }
        }
        .onAppear {
            if !storedColor.isSystem {
                pickerColor = Color(red: storedColor.red, green: storedColor.green, blue: storedColor.blue)
            }
        }
    }

    // MARK: - Swatch Button

    private func swatchButton(isSelected: Bool, content: some View, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                content
                    .frame(width: 16, height: 16)
                    .clipShape(Circle())
                if isSelected {
                    Circle()
                        .strokeBorder(.primary, lineWidth: 2)
                        .frame(width: 22, height: 22)
                }
            }
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Custom Picker

    private var isCustomSelected: Bool {
        guard !storedColor.isSystem else { return false }
        return !Self.presets.contains { isMatch($0.2) }
    }

    private var customPickerButton: some View {
        ZStack {
            // The native ColorPicker scaled down and clipped to a circle
            ColorPicker("", selection: $pickerColor, supportsOpacity: false)
                .labelsHidden()
                .scaleEffect(1.5)
                .frame(width: 16, height: 16)
                .clipShape(Circle())
                .onChange(of: pickerColor) {
                    if let c = pickerColor.cgColor?.components, c.count >= 3 {
                        storedColor = StoredColor(red: c[0], green: c[1], blue: c[2])
                    }
                }

            // Paintbrush overlay to indicate it's a custom picker
            Image(systemName: "paintbrush.pointed.fill")
                .font(.system(size: 7))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 0.5)
                .allowsHitTesting(false)

            if isCustomSelected {
                Circle()
                    .strokeBorder(.primary, lineWidth: 2)
                    .frame(width: 22, height: 22)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 26, height: 26)
        .help("Custom color")
    }

    private func isMatch(_ other: StoredColor) -> Bool {
        abs(storedColor.red - other.red) < 0.05 &&
        abs(storedColor.green - other.green) < 0.05 &&
        abs(storedColor.blue - other.blue) < 0.05
    }
}
