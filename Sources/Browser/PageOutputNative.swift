import AppKit
import WebKit

@MainActor final class PageOutputNative {
    private var prints: [UUID: PrintJob] = [:]
    var environment: PageOutputEnvironment {
        PageOutputEnvironment(capture: { web, format, completion in
            switch format {
            case .pdf: web.createPDF(configuration: WKPDFConfiguration()) { completion($0) }
            case .webArchive: web.createWebArchiveData { completion($0) }
            }
        }, choose: { window, name, format, completion in
            let panel = Self.savePanel(name: name, format: format)
            panel.beginSheetModal(for: window) { [weak panel] result in completion(result == .OK ? panel?.url : nil) }
            return { [weak panel] in panel?.cancel(nil) }
        }, print: { [self] web, window, completion in
            let id = UUID()
            let job = PrintJob(operation: Self.printOperation(for: web), window: window) { [weak self] success in
                self?.prints.removeValue(forKey: id); completion(success)
            }
            prints[id] = job; job.run()
            return { [weak self, weak job] in if self?.prints[id] === job { job?.cancel() } }
        }, write: { data, destination, completion in
            Task {
                let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                    let access = destination.startAccessingSecurityScopedResource()
                    defer { if access { destination.stopAccessingSecurityScopedResource() } }
                    do { try data.write(to: destination, options: .atomic); return .success(()) }
                    catch { return .failure(error) }
                }.value
                completion(result)
            }
        }, reportError: { message, window in
            let alert = Self.errorAlert(message: message)
            alert.beginSheetModal(for: window) { _ in }
        })
    }
    static func savePanel(name: String, format: PageOutputFormat) -> NSSavePanel {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        panel.allowedContentTypes = [format.contentType]; panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false; panel.canCreateDirectories = true
        return panel
    }
    static func printOperation(for web: WKWebView) -> NSPrintOperation {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit; info.verticalPagination = .automatic
        let operation = web.printOperation(with: info)
        operation.jobTitle = (PageOutputFormat.pdf.suggestedName(web.title) as NSString).deletingPathExtension
        operation.showsPrintPanel = true; operation.showsProgressPanel = true
        return operation
    }
    static func errorAlert(message: String) -> NSAlert {
        let alert = NSAlert(); alert.messageText = "Unable to save page"
        alert.informativeText = String(message.prefix(1000)); alert.addButton(withTitle: "OK")
        return alert
    }
    @MainActor private final class PrintJob: NSObject {
        let operation: NSPrintOperation
        weak var window: NSWindow?
        weak var sheet: NSWindow?
        let completion: (Bool) -> Void
        var completed = false
        init(operation: NSPrintOperation, window: NSWindow, completion: @escaping (Bool) -> Void) {
            self.operation = operation; self.window = window; self.completion = completion
        }
        func run() {
            guard let window else { completion(false); return }
            operation.runModal(for: window, delegate: self, didRun: #selector(didRun(_:success:contextInfo:)), contextInfo: nil)
            sheet = window.attachedSheet
        }
        func cancel() { if let window, let sheet, sheet.sheetParent === window { window.endSheet(sheet, returnCode: .cancel) } }
        @objc func didRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            guard !completed else { return }; completed = true; completion(success)
        }
    }
}
