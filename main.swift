// ScannerDiapo — numérisation de diapos/négatifs pour scanner Silvercrest (Sonix 0C45:6366, UVC)
import SwiftUI
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

let scannerVID = 0x0C45, scannerPID = 0x6366

enum FilmType: String, CaseIterable, Identifiable {
    case positif = "Diapo couleur"
    case negatifCouleur = "Négatif couleur"
    case negatifNB = "Négatif N&B"
    case positifNB = "Diapo N&B"
    var id: String { rawValue }
    var isNegative: Bool { self == .negatifCouleur || self == .negatifNB }
    var isBW: Bool { self == .negatifNB || self == .positifNB }
}

enum OutFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG", tiff = "TIFF 16 bits"
    var id: String { rawValue }
}

/// Niveaux par canal : sortie = (entrée - noir) * gain
/// Pour les négatifs : densités (−log10 de la transmission) du fond du film (lo) et des zones les plus denses (hi)
struct Levels {
    var black = [0.0, 0.0, 0.0], white = [1.0, 1.0, 1.0]
    var densLo = [0.0, 0.0, 0.0], densHi = [1.0, 1.0, 1.0]
}

final class Scanner: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    // Réglages
    @Published var film: FilmType = .positif { didSet { levelsDirty = true } }
    @Published var autoLevels = true { didSet { levelsDirty = true } }
    @Published var rotation = 0          // quarts de tour
    @Published var mirrorH = false
    @Published var mirrorV = false
    @Published var crop = 0.0             // % rogné de chaque côté
    @Published var exposure = 0.0
    @Published var contrast = 1.0
    @Published var saturation = 1.0
    @Published var frames = 4             // images moyennées par scan
    @Published var format: OutFormat = .jpeg
    @Published var prefix = "diapo"
    @Published var counter = 1
    @Published var folder: URL
    // Déclencheurs (le bouton physique n'est pas lisible sur Mac)
    @Published var autoScan = false { didSet { queue.async { self.autoState = .attenteStable; self.stableFrames = 0 } } }
    @Published var clapScan = false { didSet { clapScan ? startClap() : stopClap() } }
    @Published var clapSensitivity = 50.0   // %
    @Published var clapFlash = false

    // État
    @Published var preview: CGImage?
    @Published var lastSaved: URL?
    @Published var lastThumb: CGImage?
    @Published var status = "Recherche du scanner…"
    @Published var busy = false

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "capture")
    private let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])
    private var lastFrame: CIImage?
    private var lastFrameTime = Date()
    private var cameraStarted = false
    private var levels = Levels()
    private var levelsDirty = true
    private var lastLevelsTime = Date.distantPast
    private var frameCount = 0
    private var accum: [CIImage] = []
    private var accumTarget = 0
    // Scan auto : on attend un changement d'image, puis qu'elle soit stable
    private enum AutoState { case attenteMouvement, attenteStable }
    private var autoState = AutoState.attenteStable
    private var prevSig: [Float]?
    private var lastScanSig: [Float]?
    private var stableFrames = 0
    // Clap
    private let audio = AVAudioEngine()
    private var noiseFloor: Float = 0.01
    private var lastClap = Date.distantPast

    override init() {
        let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        folder = pics.appendingPathComponent("Diapos")
        super.init()
        let d = UserDefaults.standard
        if let p = d.string(forKey: "folder") { folder = URL(fileURLWithPath: p) }
        if let p = d.string(forKey: "prefix") { prefix = p }
        if d.integer(forKey: "counter") > 0 { counter = d.integer(forKey: "counter") }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        bumpCounterPastExisting()
    }

    // MARK: caméra

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { self.setStatus("Accès caméra refusé (Réglages > Confidentialité > Caméra)"); return }
            self.queue.async { self.configure() }
        }
        startKeys()
        // Uniquement le scanner : le micro du clap ou un iPhone déclenchent aussi ces notifications,
        // et reconstruire la session en marche figeait le flux vidéo.
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) { n in
            guard let d = n.object as? AVCaptureDevice, self.isScanner(d) else { return }
            self.queue.async { self.restartCamera("Scanner rebranché") }
        }
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { n in
            guard let d = n.object as? AVCaptureDevice, self.isScanner(d) else { return }
            self.queue.async { self.cancelScan(); self.setStatus("Scanner débranché") }
        }
        NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { _ in
            self.queue.async { self.restartCamera("Erreur caméra, redémarrage…") }
        }
        // Chien de garde : plus d'image depuis 3 s → on relance la caméra
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.queue.async {
                guard self.cameraStarted, Date().timeIntervalSince(self.lastFrameTime) > 3 else { return }
                self.restartCamera("Plus d'image du scanner, redémarrage…")
            }
        }
    }

    private func isScanner(_ d: AVCaptureDevice) -> Bool {
        d.hasMediaType(.video) && d.modelID.contains("VendorID_\(scannerVID)") && d.modelID.contains("ProductID_\(scannerPID)")
    }

    /// À appeler sur `queue` : session arrêtée et reconstruite de zéro
    private func restartCamera(_ why: String) {
        NSLog("Redémarrage caméra : %@", why)
        setStatus(why)
        cancelScan()
        session.stopRunning()
        lastFrameTime = Date()     // laisse 3 s à la nouvelle session avant la prochaine relance
        configure()
    }

    /// À appeler sur `queue` : abandonne une numérisation qui ne reçoit plus d'images
    private func cancelScan() {
        guard accumTarget > 0 else { return }
        accum = []; accumTarget = 0
        DispatchQueue.main.async { self.busy = false }
    }

    private func findDevice() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) { types = [.external] } else { types = [.externalUnknown] }
        let devs = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        return devs.first { isScanner($0) }
    }

    private func configure() {
        guard let dev = findDevice() else { cameraStarted = false; setStatus("Scanner introuvable — branche-le en USB"); return }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        guard let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
            session.commitConfiguration(); setStatus("Impossible d'ouvrir \(dev.localizedName)"); return
        }
        session.addInput(input)
        // Format le plus grand, puis le plus rapide
        let best = dev.formats.max { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            let pa = Int(da.width) * Int(da.height), pb = Int(db.width) * Int(db.height)
            if pa != pb { return pa < pb }
            return (a.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 0) < (b.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 0)
        }
        if let best, (try? dev.lockForConfiguration()) != nil {
            dev.activeFormat = best
            dev.unlockForConfiguration()
        }
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(out)
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
        lastFrameTime = Date(); cameraStarted = true
        let dim = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
        setStatus("Prêt — \(dev.localizedName) \(dim.width)×\(dim.height). Espace, Entrée, auto ou clap pour numériser.")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        // Copie : le pixel buffer est recyclé par AVFoundation
        let img = CIImage(cvPixelBuffer: pb)
        guard let cg = ctx.createCGImage(img, from: img.extent) else { return }
        let frame = CIImage(cgImage: cg)
        lastFrame = frame
        lastFrameTime = Date()

        if accumTarget > 0 {
            accum.append(frame)
            DispatchQueue.main.async { self.status = "Numérisation… \(self.accum.count)/\(self.accumTarget)" }
            if accum.count >= accumTarget { finishScan() }
            return
        }

        frameCount += 1
        let sig = signature(frame)
        if autoScan { autoStep(sig) }
        prevSig = sig
        if accumTarget > 0 { return }   // autoStep vient de lancer un scan
        if levelsDirty || Date().timeIntervalSince(lastLevelsTime) > 0.7 {
            levels = computeLevels(orient(frame))
            levelsDirty = false; lastLevelsTime = Date()
        }
        let p = process(frame, levels: levels)
        let scale = min(1, 1100 / max(p.extent.width, p.extent.height))
        let small = p.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let cg = ctx.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) {
            DispatchQueue.main.async { self.preview = cg }
        }
    }

    // MARK: traitement

    /// Rotation, miroirs et rognage (avant les couleurs, pour que les stats ignorent le cadre)
    func orient(_ img: CIImage) -> CIImage {
        // Bande noire fixe du scanner à gauche de l'image brute (~55 px + dégradé)
        let leftTrim: CGFloat = 60
        var i = img.cropped(to: CGRect(x: leftTrim, y: 0, width: img.extent.width - leftTrim, height: img.extent.height))
        if mirrorH { i = i.oriented(.upMirrored) }
        if mirrorV { i = i.oriented(.downMirrored) }
        let orients: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        i = i.oriented(orients[((rotation % 4) + 4) % 4])
        i = i.transformed(by: CGAffineTransform(translationX: -i.extent.minX, y: -i.extent.minY))
        if crop > 0 {
            let dx = i.extent.width * crop / 100, dy = i.extent.height * crop / 100
            i = i.cropped(to: i.extent.insetBy(dx: dx, dy: dy))
            i = i.transformed(by: CGAffineTransform(translationX: -i.extent.minX, y: -i.extent.minY))
        }
        return i
    }

    /// Percentiles par canal sur une version réduite du centre de l'image
    func computeLevels(_ oriented: CIImage) -> Levels {
        if film.isNegative { return negativeLevels(oriented) }
        guard autoLevels else { return Levels() }
        let src = oriented
        let e = src.extent
        let center = src.cropped(to: e.insetBy(dx: e.width * 0.08, dy: e.height * 0.08))
        let s = 256 / max(center.extent.width, center.extent.height)
        var small = center.transformed(by: CGAffineTransform(scaleX: s, y: s))
        small = small.transformed(by: CGAffineTransform(translationX: -small.extent.minX, y: -small.extent.minY))
        // on lit 1 px en retrait : les bords sont semi-transparents (donc noirs) et faussaient le point noir
        let w = Int(small.extent.width) - 2, h = Int(small.extent.height) - 2
        guard w > 4, h > 4 else { return Levels() }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        ctx.render(small, toBitmap: &buf, rowBytes: w * 4, bounds: CGRect(x: 1, y: 1, width: w, height: h), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var hist = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        for p in stride(from: 0, to: buf.count, by: 4) {
            hist[0][Int(buf[p])] += 1; hist[1][Int(buf[p + 1])] += 1; hist[2][Int(buf[p + 2])] += 1
        }
        let total = w * h
        func pct(_ hh: [Int], _ q: Double) -> Double {
            let target = Int(Double(total) * q); var acc = 0
            for (v, c) in hh.enumerated() { acc += c; if acc >= target { return Double(v) / 255 } }
            return 1
        }
        var l = Levels()
        for c in 0..<3 {
            l.black[c] = pct(hist[c], 0.002)
            l.white[c] = max(l.black[c] + 0.05, pct(hist[c], 0.998))
        }
        if !film.isNegative || film.isBW {
            // positif : mêmes niveaux sur les 3 canaux pour ne pas fausser les couleurs
            let b = l.black.min()!, w = l.white.max()!
            l.black = [b, b, b]; l.white = [w, w, w]
        }
        return l
    }

    /// Échantillon réduit du centre de l'image, en valeurs sRGB 0…1 (r, g, b à la suite)
    private func sample(_ img: CIImage) -> [Float] {
        let e = img.extent
        let center = img.cropped(to: e.insetBy(dx: e.width * 0.08, dy: e.height * 0.08))
        let s = 256 / max(center.extent.width, center.extent.height)
        var small = center.transformed(by: CGAffineTransform(scaleX: s, y: s))
        small = small.transformed(by: CGAffineTransform(translationX: -small.extent.minX, y: -small.extent.minY))
        let w = Int(small.extent.width) - 2, h = Int(small.extent.height) - 2   // bords semi-transparents exclus
        guard w > 4, h > 4 else { return [] }
        var buf = [Float](repeating: 0, count: w * h * 4)
        ctx.render(small, toBitmap: &buf, rowBytes: w * 16, bounds: CGRect(x: 1, y: 1, width: w, height: h),
                   format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var out = [Float](); out.reserveCapacity(w * h * 3)
        for p in stride(from: 0, to: buf.count, by: 4) { out += [buf[p], buf[p + 1], buf[p + 2]] }
        return out
    }

    private static func srgbToLinear(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
    }

    private static func density(_ srgb: Float) -> Float {
        -log10f(max(srgbToLinear(srgb), 1e-4))
    }

    /// Négatifs : on travaille en densité, comme un vrai tirage.
    /// lo = fond du film (retire le masque orange), hi = zones les plus denses (hautes lumières du positif).
    private func negativeLevels(_ oriented: CIImage) -> Levels {
        let px = sample(oriented)
        guard !px.isEmpty else { return Levels() }
        let n = px.count / 3
        var dens = [[Float]](repeating: [], count: 3)
        var clipped = [0, 0, 0]
        for i in 0..<n {
            for c in 0..<3 {
                let v = px[i * 3 + c]
                dens[c].append(Self.density(v))
                if v < 3.0 / 255 { clipped[c] += 1 }
            }
        }
        if film.isBW {
            // N&B : une seule courbe pour les 3 canaux
            let all = (0..<n).map { i in (dens[0][i] + dens[1][i] + dens[2][i]) / 3 }.sorted()
            let lo = Double(all[Int(Float(n) * 0.005)]), hi = Double(all[Int(Float(n) * 0.995)])
            let h = max(lo + 0.1, hi)
            return Levels(densLo: [lo, lo, lo], densHi: [h, h, h])
        }
        let sorted = dens.map { $0.sorted() }
        func pct(_ c: Int, _ q: Float) -> Float { sorted[c][min(n - 1, Int(Float(n) * q))] }
        let lo = (0..<3).map { pct($0, 0.005) }
        var hi = (0..<3).map { max(lo[$0] + 0.1, pct($0, 0.995)) }
        func median(_ c: Int, _ h: Float) -> Float {
            let l = lo[c]
            return sorted[c][n / 2] > h ? 1 : max(0, (sorted[c][n / 2] - l) / (h - l))
        }
        // Canal saturé (souvent le bleu, derrière le masque orange) : ses densités hautes sont du bruit.
        // On cale alors son échelle pour que sa médiane rejoigne celle des autres canaux (équilibre des gris).
        let bad = (0..<3).filter { Float(clipped[$0]) / Float(n) > 0.01 }
        let good = (0..<3).filter { !bad.contains($0) }
        if !bad.isEmpty && !good.isEmpty {
            let target = good.map { median($0, hi[$0]) }.reduce(0, +) / Float(good.count)
            for c in bad {
                var a = lo[c] + 0.1, b: Float = 4
                for _ in 0..<30 {
                    let m = (a + b) / 2
                    if median(c, m) > target { a = m } else { b = m }
                }
                hi[c] = (a + b) / 2
            }
        }
        return Levels(densLo: lo.map(Double.init), densHi: hi.map(Double.init))
    }

    /// Courbe par canal : valeur sRGB du négatif → densité → valeur sRGB du positif
    private func negativeCurve(_ img: CIImage, _ l: Levels) -> CIImage {
        let N = 4096
        var data = [Float](repeating: 0, count: N * 3)
        for k in 0..<N {
            let d = Self.density(Float(k) / Float(N - 1))
            for c in 0..<3 {
                let lo = Float(l.densLo[c]), hi = Float(l.densHi[c])
                data[k * 3 + c] = min(1, max(0, (d - lo) / (hi - lo)))
            }
        }
        let f = CIFilter(name: "CIColorCurves")!
        f.setValue(img, forKey: kCIInputImageKey)
        f.setValue(data.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: "inputCurvesData")
        f.setValue(CIVector(x: 0, y: 1), forKey: "inputCurvesDomain")
        f.setValue(CGColorSpace(name: CGColorSpace.sRGB)!, forKey: "inputColorSpace")
        return f.outputImage!
    }

    func process(_ frame: CIImage, levels: Levels) -> CIImage {
        var i = orient(frame)
        if film.isNegative {
            i = negativeCurve(i, levels)
            if film.isBW { let f = CIFilter.photoEffectMono(); f.inputImage = i; i = f.outputImage! }
            return adjust(i)
        }
        if film.isBW { let f = CIFilter.photoEffectMono(); f.inputImage = i; i = f.outputImage! }
        // niveaux (en valeurs sRGB, comme les stats) via un passage en espace gamma
        let g = CIFilter.linearToSRGBToneCurve(); g.inputImage = i; i = g.outputImage!
        let m = CIFilter.colorMatrix(); m.inputImage = i
        let gain = (0..<3).map { 1 / (levels.white[$0] - levels.black[$0]) }
        m.rVector = CIVector(x: gain[0], y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: gain[1], z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: gain[2], w: 0)
        m.biasVector = CIVector(x: -levels.black[0] * gain[0], y: -levels.black[1] * gain[1], z: -levels.black[2] * gain[2], w: 0)
        i = m.outputImage!.clampedToExtent().cropped(to: i.extent)
        let cl = CIFilter.colorClamp(); cl.inputImage = i; i = cl.outputImage!
        let back = CIFilter.sRGBToneCurveToLinear(); back.inputImage = i; i = back.outputImage!
        return adjust(i)
    }

    /// Réglages manuels (exposition, contraste, saturation)
    private func adjust(_ img: CIImage) -> CIImage {
        var i = img
        if exposure != 0 { let f = CIFilter.exposureAdjust(); f.inputImage = i; f.ev = Float(exposure); i = f.outputImage! }
        if contrast != 1 || saturation != 1 {
            let f = CIFilter.colorControls(); f.inputImage = i
            f.contrast = Float(contrast); f.saturation = film.isBW ? 0 : Float(saturation); i = f.outputImage!
        }
        return i
    }

    // MARK: numérisation

    func scan() { queue.async { self.startScan() } }

    /// À appeler sur `queue`
    private func startScan() {
        guard accumTarget == 0, lastFrame != nil else { return }
        accum = []
        accumTarget = max(1, frames)
        DispatchQueue.main.async { self.busy = true }
    }

    // MARK: scan automatique

    /// Vignette 64×40 en niveaux de gris (0…1) pour comparer les images entre elles
    private func signature(_ frame: CIImage) -> [Float] {
        let w = 64, h = 40
        let s = frame.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / frame.extent.width, y: CGFloat(h) / frame.extent.height))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        ctx.render(s, toBitmap: &buf, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: nil)
        return stride(from: 0, to: buf.count, by: 4).map { (Float(buf[$0]) + Float(buf[$0 + 1]) + Float(buf[$0 + 2])) / 765 }
    }

    private func diff(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Float(a.count)
    }

    /// Pas de diapo : image uniforme (rétroéclairage blanc ou noir)
    private func isEmpty(_ s: [Float]) -> Bool {
        let mean = s.reduce(0, +) / Float(s.count)
        let variance = s.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(s.count)
        return variance.squareRoot() < 0.04
    }

    private func autoStep(_ sig: [Float]) {
        guard accumTarget == 0, let prev = prevSig else { return }
        let d = diff(sig, prev)
        switch autoState {
        case .attenteMouvement:
            // mouvement franc, ou image devenue différente de la dernière numérisée (dérive lente de l'exposition)
            if d > 0.03 || (lastScanSig.map { diff(sig, $0) > 0.08 } ?? true) {
                autoState = .attenteStable; stableFrames = 0
                setStatus("Auto : changement détecté, attente d'une image stable…")
            }
        case .attenteStable:
            stableFrames = d < 0.004 ? stableFrames + 1 : 0   // bruit capteur ≈ 0,001 ; exposition qui se cale ≈ 0,005–0,03
            guard stableFrames >= 10 else { return }   // ~1 s stable (l'exposition auto s'est calée)
            autoState = .attenteMouvement
            if isEmpty(sig) { setStatus("Auto : pas de diapo, en attente…"); return }
            if let l = lastScanSig, diff(sig, l) < 0.03 { setStatus("Auto : même diapo, en attente…"); return }
            startScan()
        }
    }

    // MARK: clap des mains

    private func startClap() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                guard ok else { self.clapScan = false; self.status = "Accès micro refusé (Réglages > Confidentialité > Micro)"; return }
                let input = self.audio.inputNode
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in
                    guard let ch = buf.floatChannelData?[0] else { return }
                    let n = Int(buf.frameLength)
                    var peak: Float = 0, sum: Float = 0
                    for i in 0..<n { let v = abs(ch[i]); peak = max(peak, v); sum += v * v }
                    self.handleAudio(peak: peak, rms: (sum / Float(max(n, 1))).squareRoot())
                }
                do { try self.audio.start(); self.status = "Clap activé : claque des mains pour numériser" }
                catch { self.clapScan = false; self.status = "Micro indisponible : \(error.localizedDescription)" }
            }
        }
    }

    private func stopClap() {
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
    }

    /// Un clap = pic fort et soudain par rapport au bruit ambiant
    private func handleAudio(peak: Float, rms: Float) {
        let s = Float(clapSensitivity / 100)
        let threshold = 0.6 - 0.55 * s            // 0,6 (peu sensible) … 0,05 (très sensible)
        let isClap = peak > threshold && peak > noiseFloor * 10
        if !isClap { noiseFloor = noiseFloor * 0.98 + max(rms, 0.001) * 0.02; return }
        guard Date().timeIntervalSince(lastClap) > 1.5 else { return }
        lastClap = Date()
        DispatchQueue.main.async {
            self.clapFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.clapFlash = false }
            if !self.busy { self.scan() }
        }
    }

    private func finishScan() {
        let imgs = accum
        accum = []; accumTarget = 0
        // Moyenne des images en virgule flottante (réduit le bruit du capteur)
        var sum = imgs[0]
        if imgs.count > 1 {
            for (k, img) in imgs.enumerated().dropFirst() {
                let f = CIFilter.dissolveTransition()   // moyenne cumulative : mix = 1/(k+1)
                f.inputImage = sum; f.targetImage = img; f.time = Float(1.0 / Double(k + 1))
                sum = f.outputImage!.cropped(to: imgs[0].extent)
            }
        }
        lastScanSig = signature(sum)
        autoState = .attenteMouvement   // en auto, le prochain scan attend une nouvelle diapo
        let lv = computeLevels(orient(sum))
        let out = process(sum, levels: lv)
        let url = nextURL()
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            switch format {
            case .jpeg:
                try ctx.writeJPEGRepresentation(of: out, to: url, colorSpace: cs,
                    options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95])
            case .tiff:
                try ctx.writeTIFFRepresentation(of: out, to: url, format: .RGBA16, colorSpace: cs)
            }
            let s = 240 / max(out.extent.width, out.extent.height)
            let thumb = ctx.createCGImage(out.transformed(by: CGAffineTransform(scaleX: s, y: s)),
                                          from: out.extent.applying(CGAffineTransform(scaleX: s, y: s)), format: .RGBA8, colorSpace: cs)
            DispatchQueue.main.async {
                self.lastSaved = url; self.lastThumb = thumb
                self.counter += 1; self.saveDefaults()
                self.busy = false
                self.status = "Enregistré : \(url.lastPathComponent) (\(Int(out.extent.width))×\(Int(out.extent.height)))"
                NSSound(named: "Tink")?.play()
            }
        } catch {
            DispatchQueue.main.async { self.busy = false; self.status = "Erreur d'écriture : \(error.localizedDescription)" }
        }
    }

    private func nextURL() -> URL {
        let ext = format == .jpeg ? "jpg" : "tif"
        var n = counter
        while true {
            let u = folder.appendingPathComponent(String(format: "%@_%04d.%@", prefix, n, ext))
            if !FileManager.default.fileExists(atPath: u.path) {
                DispatchQueue.main.async { self.counter = n }
                return u
            }
            n += 1
        }
    }

    func bumpCounterPastExisting() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let nums = files.compactMap { f -> Int? in
            guard f.hasPrefix(prefix + "_") else { return nil }
            return Int(f.dropFirst(prefix.count + 1).prefix(4))
        }
        if let m = nums.max(), m >= counter { counter = m + 1 }
    }

    func saveDefaults() {
        let d = UserDefaults.standard
        d.set(folder.path, forKey: "folder"); d.set(prefix, forKey: "prefix"); d.set(counter, forKey: "counter")
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = folder
        if p.runModal() == .OK, let u = p.url { folder = u; bumpCounterPastExisting(); saveDefaults() }
    }

    private func setStatus(_ s: String) { DispatchQueue.main.async { self.status = s } }

    // MARK: clavier (le bouton physique du scanner n'est pas lisible sur Mac)

    private func startKeys() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if NSApp.keyWindow?.firstResponder is NSTextView { return e }   // on tape dans un champ
            if [36, 76, 49].contains(e.keyCode) { self.scan(); return nil }  // Entrée, Entrée pavé, Espace
            return e
        }
    }
}

// MARK: interface

struct ContentView: View {
    @EnvironmentObject var s: Scanner

    var body: some View {
        HSplitView {
            ZStack {
                Color.black
                if let p = s.preview {
                    Image(decorative: p, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.large)
                }
                if s.busy {
                    Color.black.opacity(0.35)
                    ProgressView().controlSize(.large)
                }
            }
            .frame(minWidth: 520, minHeight: 380)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Button(action: s.scan) {
                        Label("Numériser", systemImage: "camera.aperture").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(s.busy || s.preview == nil)

                    GroupBox("Déclenchement") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Auto au changement de diapo", isOn: $s.autoScan)
                                .help("Numérise dès qu'une nouvelle diapo est en place et que l'image est stable")
                            HStack {
                                Toggle("Clap des mains", isOn: $s.clapScan)
                                Spacer()
                                Text("👏").opacity(s.clapFlash ? 1 : 0.15).scaleEffect(s.clapFlash ? 1.4 : 1)
                                    .animation(.easeOut(duration: 0.2), value: s.clapFlash)
                            }
                            if s.clapScan { slider("Sensibilité", $s.clapSensitivity, 0...100, "%.0f %%") }
                            Text("Espace ou Entrée marchent aussi.").font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    GroupBox("Film") {
                        VStack(alignment: .leading) {
                            Picker("", selection: $s.film) {
                                ForEach(FilmType.allCases) { Text($0.rawValue).tag($0) }
                            }.labelsHidden()
                            Toggle("Niveaux automatiques", isOn: $s.autoLevels)
                                .disabled(s.film.isNegative)
                                .help("Toujours actifs pour les négatifs (retrait du masque orange)")
                        }
                    }

                    GroupBox("Cadrage") {
                        VStack(alignment: .leading) {
                            HStack {
                                Button { s.rotation -= 1 } label: { Image(systemName: "rotate.left") }
                                Button { s.rotation += 1 } label: { Image(systemName: "rotate.right") }
                                Toggle("↔︎", isOn: $s.mirrorH).toggleStyle(.button).help("Miroir horizontal")
                                Toggle("↕︎", isOn: $s.mirrorV).toggleStyle(.button).help("Miroir vertical")
                            }
                            slider("Rogner les bords", $s.crop, 0...15, "%.1f %%")
                        }
                    }

                    GroupBox("Réglages") {
                        VStack(alignment: .leading) {
                            slider("Exposition", $s.exposure, -2...2, "%+.1f EV")
                            slider("Contraste", $s.contrast, 0.5...1.8, "%.2f")
                            if !s.film.isBW { slider("Saturation", $s.saturation, 0...2, "%.2f") }
                            Button("Réinitialiser") { s.exposure = 0; s.contrast = 1; s.saturation = 1 }
                        }
                    }

                    GroupBox("Enregistrement") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Format", selection: $s.format) {
                                ForEach(OutFormat.allCases) { Text($0.rawValue).tag($0) }
                            }
                            Picker("Anti-bruit", selection: $s.frames) {
                                Text("1 image").tag(1); Text("4 images").tag(4); Text("8 images").tag(8); Text("16 images").tag(16)
                            }.help("Nombre d'images moyennées par scan")
                            HStack {
                                Text("Nom")
                                TextField("", text: $s.prefix).onSubmit { s.bumpCounterPastExisting(); s.saveDefaults() }
                                Text("_").foregroundStyle(.secondary)
                                TextField("", value: $s.counter, format: .number.grouping(.never)).frame(width: 50)
                            }
                            HStack {
                                Text(s.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                                Spacer()
                                Button("Choisir…", action: s.chooseFolder)
                            }
                        }
                    }

                    if let t = s.lastThumb, let u = s.lastSaved {
                        GroupBox("Dernier scan") {
                            VStack {
                                Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 140)
                                HStack {
                                    Button("Ouvrir") { NSWorkspace.shared.open(u) }
                                    Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                                }
                            }.frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(14)
            }
            .frame(minWidth: 280, idealWidth: 300, maxWidth: 360)
        }
        .safeAreaInset(edge: .bottom) {
            Text(s.status).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
                .background(.bar)
        }
        .onAppear { s.start() }
    }

    func slider(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ fmt: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(); Text(String(format: fmt, v.wrappedValue)).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: v, in: r)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

#if !TEST
@main
struct ScannerDiapoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var scanner = Scanner()
    var body: some Scene {
        WindowGroup("Scanner de diapos") {
            ContentView().environmentObject(scanner).frame(minWidth: 860, minHeight: 560)
        }
    }
}
#endif
