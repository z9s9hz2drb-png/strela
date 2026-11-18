import PhotosUI
import SwiftUI
import VisionKit

struct AddSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var subscriptionURL = ""
    @State private var subscriptionName = ""
    @State private var manualText = ""
    @State private var showScanner = false
    @State private var photoItem: PhotosPickerItem?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        Task { @MainActor in await run { await model.importText(text) } }
                    }
                    Button {
                        showScanner = true
                    } label: {
                        Label("Сканировать QR-код", systemImage: "qrcode.viewfinder")
                    }
                    .disabled(!QRScannerView.isAvailable)
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("QR-код из фото", systemImage: "photo")
                    }
                } header: {
                    Text("Быстро")
                } footer: {
                    Text("Подходит всё: ссылка подписки, vless:// vmess:// trojan:// ss:// hy2://, Base64, JSON Xray, happ://add/… и профили happ://routing/…")
                }

                Section("Подписка") {
                    TextField("https://…", text: $subscriptionURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Название (необязательно)", text: $subscriptionName)
                    Button("Добавить подписку") {
                        let url = subscriptionURL
                        let name = subscriptionName
                        Task { await run { await model.addSubscription(url: url, name: name) } }
                    }
                    .disabled(subscriptionURL.trimmed.isEmpty)
                }

                Section {
                    TextEditor(text: $manualText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 140)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Импортировать") {
                        let text = manualText
                        Task { await run { await model.importText(text) } }
                    }
                    .disabled(manualText.trimmed.isEmpty)
                } header: {
                    Text("Вручную")
                } footer: {
                    Text("Можно вставить сразу несколько ссылок — по одной на строку.")
                }
            }
            .navigationTitle("Добавить")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .disabled(working)
            .overlay {
                if working {
                    ProgressView()
                        .controlSize(.large)
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .sheet(isPresented: $showScanner) {
                NavigationStack {
                    QRScannerView { code in
                        showScanner = false
                        Task { await run { await model.importText(code) } }
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Наведите камеру на QR-код")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Отмена") { showScanner = false }
                        }
                    }
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    photoItem = nil
                    guard let data, let code = QRCode.detect(in: data) else {
                        model.show("QR-код на изображении не найден", error: true)
                        return
                    }
                    await run { await model.importText(code) }
                }
            }
        }
    }

    private func run(_ work: () async -> Void) async {
        working = true
        await work()
        working = false
        dismiss()
    }
}

/// Live QR scanner (VisionKit DataScanner, iPad and iPhone with A12+).
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    @MainActor static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        if !controller.isScanning {
            try? controller.startScanning()
        }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var delivered = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            deliver(addedItems, scanner: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            deliver([item], scanner: dataScanner)
        }

        private func deliver(_ items: [RecognizedItem], scanner: DataScannerViewController) {
            guard !delivered else { return }
            for item in items {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue, !payload.isEmpty {
                    delivered = true
                    scanner.stopScanning()
                    onCode(payload)
                    return
                }
            }
        }
    }
}
