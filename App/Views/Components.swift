import CoreImage.CIFilterBuiltins
import NetworkExtension
import SwiftUI
import UIKit

enum StatusText {
    static func title(_ status: NEVPNStatus, preparing: Bool) -> String {
        if preparing, status != .connected { return "Подготовка…" }
        switch status {
        case .connected: return "Подключено"
        case .connecting: return "Подключение…"
        case .disconnecting: return "Отключение…"
        case .reasserting: return "Переподключение…"
        case .disconnected: return "Отключено"
        case .invalid: return "Не настроено"
        @unknown default: return "—"
        }
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .binary) + "/с"
    }

    static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}

struct LatencyBadge: View {
    let ms: Int?

    var body: some View {
        Text(label)
            .font(.caption.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        guard let ms else { return "—" }
        return ms < 0 ? "✕" : "\(ms) мс"
    }

    private var color: Color {
        guard let ms else { return .secondary }
        if ms < 0 { return .red }
        if ms < 400 { return .green }
        if ms < 900 { return .orange }
        return .red
    }
}

struct BannerView: View {
    let banner: Banner

    var body: some View {
        Label(banner.text, systemImage: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(banner.isError ? Color.red.opacity(0.4) : Color.green.opacity(0.4)))
            .foregroundStyle(banner.isError ? Color.red : Color.primary)
            .padding(.horizontal)
            .shadow(radius: 6, y: 2)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct QRItem: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

struct QRCodeSheet: View {
    let item: QRItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let image = QRCode.image(item.text) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 360)
                        .padding()
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                }
                Text(item.text)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(.horizontal)
                HStack {
                    Button {
                        UIPasteboard.general.string = item.text
                    } label: {
                        Label("Скопировать", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    ShareLink(item: item.text) {
                        Label("Поделиться", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
    }
}

enum QRCode {
    static func image(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    static func detect(in data: Data) -> String? {
        guard let image = CIImage(data: data) else { return nil }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: image) ?? []
        return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
}
