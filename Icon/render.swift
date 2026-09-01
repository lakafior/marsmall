// Rasteryzuje SVG przez WebKit - czyli tym samym silnikiem co Safari.
// Wewnetrzny renderer ImageMagicka gubi obrysy i zaokraglenia zlaczen.
//
// uzycie: swift render.swift wejscie.svg wyjscie.png [rozmiar]
import Cocoa
import WebKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: render <in.svg> <out.png> [size]\n".data(using: .utf8)!)
    exit(1)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let size = args.count > 3 ? (Double(args[3]) ?? 1024) : 1024

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

final class Renderer: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let out: URL

    init(size: Double, out: URL) {
        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: size, height: size), configuration: cfg)
        self.out = out
        super.init()
        web.navigationDelegate = self
        web.underPageBackgroundColor = .clear
        web.setValue(false, forKey: "drawsBackground")   // przezroczyste tlo zrzutu
    }

    func load(_ rawSVG: String) {
        // SVG idzie przez <img> z data URI zamiast byc wklejany do DOM.
        // Parser HTML potrafi zgubic viewBox przy wklejaniu w tresc (grafika
        // renderuje sie wtedy 1:1 i zostaje obcieta); <img> skaluje zawsze
        // poprawnie i respektuje preserveAspectRatio.
        let data = Data(rawSVG.utf8).base64EncodedString()
        let html = """
        <html><head><meta charset="utf-8"><style>
          html,body{margin:0;padding:0;background:transparent;width:100%;height:100%;}
          img{display:block;width:100%;height:100%;object-fit:contain;}
        </style></head>
        <body><img src="data:image/svg+xml;base64,\(data)"></body></html>
        """
        web.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = w.bounds
        // Krotka zwloka - inaczej zrzut potrafi zlapac pusta klatke.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            w.takeSnapshot(with: cfg) { image, error in
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    FileHandle.standardError.write("snapshot failed\n".data(using: .utf8)!)
                    exit(2)
                }
                do { try png.write(to: self.out) } catch { exit(3) }
                exit(0)
            }
        }
    }
}

let svg = (try? String(contentsOf: input, encoding: .utf8)) ?? ""
let r = Renderer(size: size, out: output)
let window = NSWindow(contentRect: r.web.frame, styleMask: [.borderless],
                      backing: .buffered, defer: false)
window.contentView = r.web
window.orderBack(nil)
r.load(svg)
app.run()
