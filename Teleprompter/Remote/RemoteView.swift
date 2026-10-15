import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

/// Turns the phone remote and the iPad display on and off, and shows the
/// addresses (with QR codes) to open on each device.
struct RemoteView: View {
    @Environment(RemoteHub.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @State private var controlPortText = ""
    @State private var displayPortText = ""

    var body: some View {
        @Bindable var hub = hub
        Form {
            Section {
                Toggle("Phone remote and iPad display", isOn: $hub.isEnabled)
                if hub.isEnabled {
                    StatusRow(status: hub.status)
                }
            } footer: {
                Text("This device hosts both pages. Open them in Safari or Chrome on any phone or iPad on the same Wi-Fi network.")
            }

            if hub.isEnabled {
                if hub.addresses.isEmpty {
                    Section {
                        Label("No network connection. Join Wi-Fi or Ethernet, then refresh.", systemImage: "wifi.slash")
                            .foregroundStyle(Signal.warning)
                        Button("Refresh", action: hub.refreshAddresses)
                    }
                } else {
                    Section {
                        LinkCard(title: "Phone remote",
                                 detail: "Play, pause, speed, jumps and script picker.",
                                 url: hub.controlURL ?? "",
                                 connected: hub.remoteCount)
                    } header: {
                        SectionHeader("Control · port \(String(hub.controlPort))")
                    }

                    Section {
                        LinkCard(title: "iPad display",
                                 detail: "Full-screen prompter that follows this device. Add it to the Home Screen for no browser bars.",
                                 url: hub.displayURL ?? "",
                                 connected: hub.displayCount)
                        Toggle("Mirror display", isOn: $hub.display.mirror)
                        Toggle("Flip display upside down", isOn: $hub.display.flip)
                        LabeledContent("Display text size") {
                            Stepper("\(Int((hub.display.scale * 100).rounded()))%",
                                    value: $hub.display.scale, in: DisplayOptions.scaleRange, step: 0.1)
                        }
                    } header: {
                        SectionHeader("Present · port \(String(hub.displayPort))")
                    } footer: {
                        Text("Mirroring here flips only the display, so this screen stays readable.")
                    }

                    if hub.addresses.count > 1 {
                        Section {
                            ForEach(hub.addresses.dropFirst(), id: \.self) { address in
                                Text(address).signal(.mono).textSelection(.enabled)
                            }
                        } header: {
                            SectionHeader("Other addresses")
                        } footer: {
                            Text("Try these if the device is on a second network, such as Ethernet and Wi-Fi together.")
                        }
                    }
                }

                Section {
                    LabeledContent("Control port") {
                        TextField("7070", text: $controlPortText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Present port") {
                        TextField("7071", text: $displayPortText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Button("Apply ports", action: applyPorts)
                        .disabled(!portsAreValid || !portsChanged)
                } header: {
                    SectionHeader("Ports")
                } footer: {
                    Text("Change these only if another app already uses them. Use two different numbers between 1024 and 65535.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Signal.bg)
        .navigationTitle("Remote and display")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            hub.refreshAddresses()
            controlPortText = String(hub.controlPort)
            displayPortText = String(hub.displayPort)
        }
    }

    private var parsedPorts: (UInt16, UInt16)? {
        guard let c = UInt16(controlPortText), let d = UInt16(displayPortText) else { return nil }
        return (c, d)
    }

    private var portsAreValid: Bool {
        guard let (c, d) = parsedPorts else { return false }
        return c > 1023 && d > 1023 && c != d
    }

    private var portsChanged: Bool {
        guard let (c, d) = parsedPorts else { return false }
        return c != hub.controlPort || d != hub.displayPort
    }

    private func applyPorts() {
        guard let (c, d) = parsedPorts else { return }
        hub.setPorts(control: c, display: d)
    }
}

private struct StatusRow: View {
    let status: RemoteHub.Status

    var body: some View {
        switch status {
        case .off:
            Label("Off", systemImage: "circle").foregroundStyle(Signal.inkSubtle)
        case .starting:
            Label("Starting", systemImage: "hourglass").foregroundStyle(Signal.inkMuted)
        case .running:
            Label("Running", systemImage: "checkmark.circle.fill").foregroundStyle(Signal.success)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Signal.danger)
        }
    }
}

private struct LinkCard: View {
    let title: String
    let detail: String
    let url: String
    let connected: Int

    var body: some View {
        HStack(alignment: .top, spacing: Signal.Space.s4) {
            QRCode(text: url)
                .frame(width: 112, height: 112)
                .accessibilityLabel("QR code for \(url)")
            VStack(alignment: .leading, spacing: Signal.Space.s2) {
                Text(title).signal(.subheading).foregroundStyle(Signal.ink)
                Text(url)
                    .signal(.mono)
                    .foregroundStyle(Signal.accent)
                    .textSelection(.enabled)
                Text(detail).signal(.bodySmall).foregroundStyle(Signal.inkMuted)
                Text(connected == 0 ? "Not connected" : connected == 1 ? "1 connected" : "\(connected) connected")
                    .signal(.label)
                    .foregroundStyle(connected > 0 ? Signal.success : Signal.inkSubtle)
                Button {
                    UIPasteboard.general.string = url
                } label: {
                    Label("Copy link", systemImage: "doc.on.doc")
                }
                .signal(.label)
            }
        }
        .padding(.vertical, Signal.Space.s2)
    }
}

/// A crisp QR code for a short URL.
private struct QRCode: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(Signal.Space.s2)
                .background(Color.white, in: RoundedRectangle(cornerRadius: Signal.Radius.sm))
        } else {
            RoundedRectangle(cornerRadius: Signal.Radius.sm).fill(Signal.surfaceRaised)
        }
    }

    private static func render(_ text: String) -> UIImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
