@testable import QMIHost
import QMIDAPI
@testable import QMIKit
import XCTest

final class ConversionsTests: XCTestCase {
    private func card(_ state: UInt8, pin: UInt8? = nil) -> UIM.Card {
        UIM.Card(state: state, applications: [], pin: pin.map { UIM.Card.PIN(state: $0, retries: 3, pukRetries: 10) })
    }

    func testCardState() {
        XCTAssertEqual(card(0).simCardState, .absent)
        XCTAssertEqual(card(1).simCardState, .present)
        XCTAssertEqual(card(2).simCardState, .error)
        XCTAssertEqual(card(9).simCardState, .error)
    }

    func testMainCard() {
        XCTAssertEqual(UIM.Card.main(of: [card(0), card(1, pin: 2)]), card(1, pin: 2))
        XCTAssertEqual(UIM.Card.main(of: [card(0), card(2)]), card(0))
        XCTAssertNil(UIM.Card.main(of: []))
    }

    func testPINState() {
        XCTAssertEqual((0...6).map { UIM.Card.PIN(state: $0, retries: 0, pukRetries: 0).simState },
                       [.disabled, .required, .verified, .disabled, .pukRequired, .blocked, .unknown])
    }

    func testHomeNetwork() {
        let p = PLMNID(mcc: 1, mnc: 1)
        XCTAssertTrue(p.isHome("00101"))
        XCTAssertTrue(p.isHome("001001"))          // a 3-digit MNC spelling of the same network
        XCTAssertFalse(p.isHome("00102"))
        XCTAssertFalse(p.isHome("0010"))
        XCTAssertFalse(p.isHome(nil))
    }

    func testCell() {
        var c = NAS.Cell(rat: .nr, role: .secondary)
        c.channel = 627264
        c.pci = 12
        c.scellIndex = 1
        let q = QMIDCell(c)
        XCTAssertEqual(q.ratKind, .nr)
        XCTAssertEqual(q.roleKind, .secondary)
        XCTAssertEqual(q.band, QMIDCell.band(.nr, channel: 627264))   // from the channel
        XCTAssertEqual(q.pci, 12)
        XCTAssertEqual(q.scellIndex, 1)
        c.band = 78
        XCTAssertEqual(QMIDCell(c).band, 78)                            // the modem's wins
        XCTAssertEqual(QMIDCell(NAS.Cell(rat: .lte, role: .neighbor)).roleKind, .neighbor)
    }

    func testAMBR() {
        XCTAssertEqual(QMIDAMBR(WDS.AMBR(uplink: 1, downlink: 2)), QMIDAMBR(uplink: 1, downlink: 2))
    }
}
