//
//  UploadQueueTests.swift
//  ArgosTests
//
//  Cola de subidas del terminal: estado puro, troceado SFTP y el modelo que la procesa.
//

import Testing
import Foundation
@testable import Argos

@Suite("Cola de subidas (estado)")
struct UploadQueueStateTests {

    private func item(_ name: String, _ bytes: Int, _ state: UploadQueueItem.State = .waiting) -> UploadQueueItem {
        UploadQueueItem(name: name, totalBytes: bytes, state: state)
    }

    @Test func elSiguienteEsElPrimeroEnEsperaSoloSiNadaSube() {
        let a = item("a", 10), b = item("b", 10)
        let queue = UploadQueue().appending([a, b])
        #expect(queue.next?.id == a.id)
        let uploading = queue.setting(.uploading(sentBytes: 3), for: a.id)
        #expect(uploading.next == nil)
        #expect(uploading.current?.id == a.id)
        let done = uploading.setting(.done(remotePath: "/tmp/a"), for: a.id)
        #expect(done.next?.id == b.id)
    }

    @Test func elProgresoGlobalVaPorBytesYIgnoraLosFallidos() {
        let a = item("a", 100, .done(remotePath: "/tmp/a"))
        let b = item("b", 300, .uploading(sentBytes: 100))
        let c = item("c", 1_000, .failed(message: "x"))
        let queue = UploadQueue(items: [a, b, c])
        #expect(queue.overallFraction == 0.5)
        #expect(queue.overallPercent == 50)
        #expect(queue.batchCount == 2)
        #expect(queue.currentPosition == 2)
        #expect(queue.failedCount == 1)
    }

    @Test func losEnviadosNoPasanDelTotal() {
        let a = item("a", 10, .uploading(sentBytes: 50))
        #expect(a.sentBytes == 10)
        #expect(a.fraction == 1)
    }

    @Test func archivosVaciosCuentanPorArchivo() {
        let queue = UploadQueue(items: [item("a", 0, .done(remotePath: "/tmp/a")), item("b", 0)])
        #expect(queue.overallFraction == 0.5)
    }

    @Test func limpiarCompletadosConservaFallosYPendientes() {
        let queue = UploadQueue(items: [
            item("a", 1, .done(remotePath: "/tmp/a")),
            item("b", 1, .failed(message: "x")),
            item("c", 1),
        ])
        #expect(queue.removingCompleted().items.map(\.name) == ["b", "c"])
        #expect(queue.removingFinished().items.map(\.name) == ["c"])
        #expect(queue.isBusy)
        #expect(!queue.removingFinished().removing(queue.items[2].id).isBusy)
    }

    @Test func elTroceadoCubreTodoSinHuecos() {
        let ranges = UploadChunking.ranges(count: 10, chunk: 4)
        #expect(ranges == [0..<4, 4..<8, 8..<10])
        #expect(UploadChunking.ranges(count: 0).isEmpty)
        #expect(UploadChunking.ranges(count: 1).count == 1)
    }
}

/// Retiene las subidas del mock hasta que el test les da paso.
private actor UploadGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals: [String] = []

    func wait(_ name: String) async {
        arrivals.append(name)
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
@Suite("Cola de subidas (proceso)")
struct TerminalUploadQueueTests {

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeQueue(_ mock: MockSSHService, maxBytes: Int = 1_000) -> (TerminalUploadQueue, Box) {
        let queue = TerminalUploadQueue(service: mock, maxBytes: maxBytes, completedLinger: .milliseconds(20))
        let box = Box()
        queue.onUploaded = { box.paths.append($0) }
        return (queue, box)
    }

    @MainActor final class Box { var paths: [String] = [] }

    @Test func subeEnOrdenYEntregaCadaRuta() async {
        let mock = MockSSHService()
        let (queue, box) = makeQueue(mock)
        queue.enqueue([.attachment(Data(count: 10), fileName: "a.txt"), .pastedImage(Data(count: 4), fileExtension: "png")])
        queue.enqueue([.attachment(Data(count: 2), fileName: "b.txt")])
        await waitUntil { box.paths.count == 3 }
        #expect(box.paths == ["/tmp/argos-test-a.txt", "/tmp/argos-test-pasted.png", "/tmp/argos-test-b.txt"])
        await waitUntil { queue.queue.isEmpty }
        #expect(queue.queue.isEmpty)
    }

    @Test func loQueLlegaMientrasSubeEsperaSuTurno() async {
        let mock = MockSSHService()
        let gate = UploadGate()
        mock.uploadGate = { await gate.wait($0) }
        let (queue, box) = makeQueue(mock)
        queue.enqueue([.attachment(Data(count: 10), fileName: "a.txt")])
        await waitUntil { queue.queue.current?.sentBytes == 5 }
        #expect(queue.queue.overallPercent == 50)
        queue.enqueue([.attachment(Data(count: 10), fileName: "b.txt")])
        #expect(queue.queue.items.count == 2)
        #expect(queue.queue.items[1].state == .waiting)
        await gate.open()
        await waitUntil { box.paths.count == 2 }
        #expect(box.paths == ["/tmp/argos-test-a.txt", "/tmp/argos-test-b.txt"])
    }

    @Test func cancelarElQueSubeLoQuitaYSigueConElResto() async {
        let mock = MockSSHService()
        let gate = UploadGate()
        mock.uploadGate = { await gate.wait($0) }
        let (queue, box) = makeQueue(mock)
        queue.enqueue([.attachment(Data(count: 10), fileName: "a.txt"), .attachment(Data(count: 10), fileName: "b.txt")])
        await waitUntil { queue.queue.current != nil }
        let first = queue.queue.items[0].id
        queue.cancel(first)
        #expect(!queue.queue.items.contains { $0.id == first })
        await gate.open()
        await waitUntil { box.paths.count == 1 }
        #expect(box.paths == ["/tmp/argos-test-b.txt"])
    }

    @Test func unFalloSeQuedaVisibleYSePuedeReintentar() async {
        let mock = MockSSHService()
        mock.uploadError = SSHService.SSHServiceError.uploadFailed("sin espacio")
        let (queue, box) = makeQueue(mock)
        queue.enqueue([.attachment(Data(count: 10), fileName: "a.txt")])
        await waitUntil { queue.queue.failedCount == 1 }
        try? await Task.sleep(for: .milliseconds(60))
        #expect(queue.queue.failedCount == 1, "los fallos no se limpian solos")
        mock.uploadError = nil
        queue.retry(queue.queue.items[0].id)
        await waitUntil { box.paths.count == 1 }
        #expect(box.paths == ["/tmp/argos-test-a.txt"])
    }

    @Test func unArchivoDemasiadoGrandeNoSeSube() async {
        let mock = MockSSHService()
        let (queue, _) = makeQueue(mock, maxBytes: 5)
        queue.enqueue([.attachment(Data(count: 10), fileName: "grande.bin")])
        #expect(queue.queue.failedCount == 1)
        #expect(!queue.queue.isBusy)
        queue.retry(queue.queue.items[0].id)
        #expect(queue.queue.failedCount == 1, "no hay nada que reintentar")
        queue.dismissFinished()
        #expect(queue.queue.isEmpty)
        #expect(mock.uploadedNames.isEmpty)
    }
}
