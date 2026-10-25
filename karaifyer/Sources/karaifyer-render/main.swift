// karaifyer-render <scene.json> <out.mp4> [--layout grille|paroles]
// The lyrics video for the pipeline's video step: the same renderer as Karaifyer's Lecteur.
import Foundation
import KaraifyerCore

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage : karaifyer-render <scene.json> <out.mp4> [--layout grille|paroles]\n".utf8))
    exit(2)
}
do {
    let scene = try VideoScene.load(url: URL(fileURLWithPath: args[1]))
    let layout = args.firstIndex(of: "--layout").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? scene.layout
    var shown = -1
    try VideoExporter.export(scene: scene, to: URL(fileURLWithPath: args[2]), layout: layout, transpose: 0) { p in
        let pct = Int(p * 10) * 10
        if pct != shown { shown = pct; print("rendu vidéo \(pct) %") }
        return true
    }
} catch {
    FileHandle.standardError.write(Data("karaifyer-render : \(error.localizedDescription)\n".utf8))
    exit(1)
}
