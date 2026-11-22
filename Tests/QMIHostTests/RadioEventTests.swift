@testable import QMIHost
import QMIDAPI
import XCTest

final class RadioEventTests: XCTestCase {
    private func radio(rsrp: Double, nrActive: Bool, neighbours: Int, nrRRC: QMIDRRCState = .connected) -> NSDictionary {
        var p = QMIDCell(rat: .lte, role: .primary)
        p.channel = 1625; p.pci = 421; p.rsrp = rsrp
        var ps = QMIDCell(rat: .nr, role: .secondary)
        ps.channel = 531870; ps.pci = 942; ps.pscell = true; ps.rsrp = rsrp + 5
        var sc = QMIDCell(rat: .nr, role: .secondary)
        sc.channel = 423500; sc.pci = 68; sc.active = nrActive
        let n = (0..<neighbours).map { i -> QMIDCell in var c = QMIDCell(rat: .lte, role: .neighbor); c.pci = i; return c }
        return QMIDRadio(cells: [p, ps, sc] + n, endcAvailable: true, lteRRC: .connected, nrRRC: nrRRC).dictionary
    }

    // Signal and neighbours don't make a radio event; activation and RRC state do.
    func testRadioKey() {
        let base = Manager.radioKey(radio(rsrp: -90, nrActive: false, neighbours: 2))
        XCTAssertEqual(Manager.radioKey(radio(rsrp: -97, nrActive: false, neighbours: 5)), base)
        XCTAssertNotEqual(Manager.radioKey(radio(rsrp: -90, nrActive: true, neighbours: 2)), base)
        XCTAssertNotEqual(Manager.radioKey(radio(rsrp: -90, nrActive: false, neighbours: 2, nrRRC: .idle)), base)
    }

    func testRRCStates() {
        XCTAssertEqual([1, 2, 3, 4, 5, 6, 7, 8].map { Manager.lteRRC($0) },
                       [.idle, .idle, .connecting, .connected, .releasing, .inactive, .idle, .suspended])
        XCTAssertNil(Manager.lteRRC(0))
        XCTAssertEqual([0, 1, 2].map { Manager.nrRRC($0) }, [.idle, .connected, .inactive])
        XCTAssertNil(Manager.nrRRC(3))
    }
}
