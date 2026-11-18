import Foundation
@MainActor final class DialState { nonisolated static let storage = URL(fileURLWithPath: "/tmp/radio-market-tests-" + String(ProcessInfo.processInfo.processIdentifier)) }
@main struct Test {
 @MainActor static func main() async throws {
  let station = BroadcastStation(callsign: "KIIS-FM", frequency: 1027, band: .fm, community: "LOS ANGELES", state: "CA", facility: "19218")
  let market = RadioMarket.all.first { $0.id == "la" }!
  func source(_ title: String, _ url: String = "https://example.com/stream", country: String = "The United States Of America") -> Source {
    Source(id: title, title: title, url: URL(string:url)!, country: country)
  }
  let saved = source("102.7 KIIS FM Los Angeles")
  precondition(MarketDirectory.matches(saved, station: station))
  precondition(MarketDirectory.matches(source("102.7 KIIS-FM"), station: station))
  precondition(!MarketDirectory.matches(source("101.5 KIIS FM"), station: station))
  precondition(!MarketDirectory.matches(source("102.7 KISS FM"), station: station))
  precondition(!MarketDirectory.matches(source("102.7 KIIS FM", country: "United Kingdom"), station: station))
  precondition(MarketDirectory.matchingSources([saved, saved], station: station).count == 1)
  let d = MarketDirectory()
  precondition(d.rememberedStream(for: station, market: market) == nil)
  d.remember(saved, for: station, market: market)
  precondition(d.rememberedStream(for: station, market: market)?.url == saved.url)
  precondition(d.rememberedStream(for: station, market: RadioMarket.all[0]) == nil)
  print("Call-sign, frequency, country, deduplication, and market-specific cache checks passed")
  try? FileManager.default.removeItem(at: DialState.storage)
 }
}
