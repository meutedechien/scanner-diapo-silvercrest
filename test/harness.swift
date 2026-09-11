// Outil de test : applique le traitement de l'appli à une image brute du scanner
// swiftc -O -parse-as-library -D TEST main.swift test/harness.swift -o test/harness
import Foundation
import CoreImage

@main struct Harness {
    static func main() {
        let a = CommandLine.arguments
        let s = Scanner()
        s.film = FilmType.allCases.first { "\($0)" == a[3] }!
        let raw = CIImage(contentsOf: URL(fileURLWithPath: a[1]))!
        let lv = s.computeLevels(s.orient(raw))
        print("densités lo", lv.densLo.map { String(format: "%.3f", $0) }, "hi", lv.densHi.map { String(format: "%.3f", $0) })
        let out = s.process(raw, levels: lv)
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])
        try! ctx.writeJPEGRepresentation(of: out, to: URL(fileURLWithPath: a[2]), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}
