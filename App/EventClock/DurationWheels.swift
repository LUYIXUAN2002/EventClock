import SwiftUI
import UIKit
import EventClockPlatform

/// Native-looking duration wheels with wrapping minute and second components.
///
/// SwiftUI's native wheel `Picker` is finite, so it cannot scroll from 59 back
/// to 00 or from 00 back to 59. This wraps a native `UIPickerView` with a large
/// virtual row range, preserving Apple's wheel appearance and haptics.
struct DurationWheels: UIViewRepresentable {
    @Binding var hours: Int
    @Binding var minutes: Int
    @Binding var seconds: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIPickerView {
        let picker = WrappingPickerView()
        picker.dataSource = context.coordinator
        picker.delegate = context.coordinator
        picker.accessibilityLabel = "Duration"
        picker.accessibilityHint = "Hours, minutes, and seconds. Minutes and seconds wrap around."
        context.coordinator.picker = picker
        picker.reloadAllComponents()
        context.coordinator.syncSelections(animated: false)

        // A picker created before layout can ignore programmatic selection.
        // Synchronize once more after its first real layout so a circular
        // component can never remain stuck at physical row 0.
        picker.onFirstLayout = { [weak coordinator = context.coordinator] in
            coordinator?.syncSelections(animated: false)
        }
        return picker
    }

    func updateUIView(_ picker: UIPickerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncSelections(animated: false)
    }

    final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewDelegate {
        var parent: DurationWheels
        weak var picker: UIPickerView?
        private var isSynchronizing = false

        init(_ parent: DurationWheels) {
            self.parent = parent
        }

        func numberOfComponents(in pickerView: UIPickerView) -> Int {
            3
        }

        func pickerView(
            _ pickerView: UIPickerView,
            numberOfRowsInComponent component: Int
        ) -> Int {
            switch component {
            case 0:
                return 25
            case 1, 2:
                return CircularWheelMath.totalRows(modulo: 60)
            default:
                return 0
            }
        }

        func pickerView(
            _ pickerView: UIPickerView,
            titleForRow row: Int,
            forComponent component: Int
        ) -> String? {
            switch component {
            case 0:
                return "\(min(max(row, 0), 24)) hr"
            case 1:
                return "\(CircularWheelMath.value(forRow: row, modulo: 60)) min"
            case 2:
                return "\(CircularWheelMath.value(forRow: row, modulo: 60)) sec"
            default:
                return nil
            }
        }

        func pickerView(
            _ pickerView: UIPickerView,
            didSelectRow row: Int,
            inComponent component: Int
        ) {
            guard !isSynchronizing else { return }

            switch component {
            case 0:
                parent.hours = min(max(row, 0), 24)
            case 1:
                let value = CircularWheelMath.value(forRow: row, modulo: 60)
                parent.minutes = value
                recenterIfNeeded(component: 1, row: row, value: value)
            case 2:
                let value = CircularWheelMath.value(forRow: row, modulo: 60)
                parent.seconds = value
                recenterIfNeeded(component: 2, row: row, value: value)
            default:
                break
            }
        }

        func syncSelections(animated: Bool) {
            guard let picker else { return }
            isSynchronizing = true
            defer { isSynchronizing = false }

            let hour = min(max(parent.hours, 0), 24)
            if picker.selectedRow(inComponent: 0) != hour {
                picker.selectRow(hour, inComponent: 0, animated: animated)
            }
            syncCircularComponent(1, value: parent.minutes, picker: picker)
            syncCircularComponent(2, value: parent.seconds, picker: picker)
        }

        private func syncCircularComponent(
            _ component: Int,
            value: Int,
            picker: UIPickerView
        ) {
            let normalized = CircularWheelMath.value(forRow: value, modulo: 60)
            let selected = picker.selectedRow(inComponent: component)
            if CircularWheelMath.shouldRepositionSelection(
                row: selected,
                value: normalized,
                modulo: 60
            ) {
                picker.selectRow(
                    CircularWheelMath.initialRow(
                        forValue: normalized,
                        modulo: 60
                    ),
                    inComponent: component,
                    animated: false
                )
            }
        }

        private func recenterIfNeeded(
            component: Int,
            row: Int,
            value: Int
        ) {
            guard CircularWheelMath.needsRecentering(row: row, modulo: 60) else {
                return
            }
            isSynchronizing = true
            picker?.selectRow(
                CircularWheelMath.recenteredRow(forValue: value, modulo: 60),
                inComponent: component,
                animated: false
            )
            isSynchronizing = false
        }
    }
}

/// UIPickerView only accepts meaningful programmatic selection after layout.
private final class WrappingPickerView: UIPickerView {
    var onFirstLayout: (() -> Void)?
    private var didSynchronizeAfterLayout = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !didSynchronizeAfterLayout,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }
        didSynchronizeAfterLayout = true
        onFirstLayout?()
    }
}
