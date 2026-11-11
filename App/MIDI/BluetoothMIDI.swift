import CoreAudioKit
import SwiftUI

/// Apple's built-in BLE-MIDI pairing screens wrapped for SwiftUI.
///  - Central: find and connect BLE controllers (WIDI, CME, Roli, Korg nano, etc.)
///  - Peripheral: advertise the iPad itself as a BLE-MIDI device (for a Mac/another iPad).
/// Once connected, BLE devices appear as normal sources/destinations in Routing.
struct BluetoothMIDICentralView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: CABTMIDICentralViewController())
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}

struct BluetoothMIDIPeripheralView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: CABTMIDILocalPeripheralViewController())
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}
