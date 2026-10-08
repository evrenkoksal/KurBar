import Foundation

struct Rate {
    let price: Double
    /// Percent change against the previous close, if the source provides it.
    let changePercent: Double?
}

struct Snapshot {
    let usd: Rate
    let eur: Rate
    /// Gram gold in TRY. Nil when the gold source is unreachable.
    let gold: Rate?
    let source: String
    let fetchedAt: Date
}

enum RateError: Error {
    case badResponse
}

/// Fetches USD/TRY, EUR/TRY and gram gold. Currencies come from Yahoo Finance
/// with finans.truncgil.com as fallback; gram gold always comes from Truncgil
/// because Yahoo has no Turkish gram gold quote.
struct RateService {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh) KurBar/1.0"]
        return URLSession(configuration: config)
    }()

    func fetch() async throws -> Snapshot {
        async let usdQuote = try? yahoo(symbol: "USDTRY=X")
        async let eurQuote = try? yahoo(symbol: "EURTRY=X")
        async let truncgilQuotes = try? truncgil()

        let (usd, eur, fallback) = await (usdQuote, eurQuote, truncgilQuotes)
        if let usd, let eur {
            return Snapshot(usd: usd, eur: eur, gold: fallback?.gold, source: "Yahoo Finance", fetchedAt: Date())
        }
        guard let fallback, let usd = fallback.usd, let eur = fallback.eur else { throw RateError.badResponse }
        return Snapshot(usd: usd, eur: eur, gold: fallback.gold, source: "Truncgil Finans", fetchedAt: Date())
    }

    private func json(_ url: URL) async throws -> [String: Any] {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw RateError.badResponse }
        return object
    }

    private func yahoo(symbol: String) async throws -> Rate {
        let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)?interval=1m&range=1d")!
        let root = try await json(url)
        guard let chart = root["chart"] as? [String: Any],
              let result = (chart["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any],
              let price = meta["regularMarketPrice"] as? Double, price > 0
        else { throw RateError.badResponse }

        let previous = (meta["chartPreviousClose"] as? Double) ?? (meta["previousClose"] as? Double)
        let change = previous.flatMap { $0 > 0 ? (price - $0) / $0 * 100 : nil }
        return Rate(price: price, changePercent: change)
    }

    private func truncgil() async throws -> (usd: Rate?, eur: Rate?, gold: Rate?) {
        let root = try await json(URL(string: "https://finans.truncgil.com/v4/today.json")!)

        func rate(_ code: String) -> Rate? {
            guard let entry = root[code] as? [String: Any],
                  let buying = entry["Buying"] as? Double,
                  let selling = entry["Selling"] as? Double, buying > 0, selling > 0
            else { return nil }
            return Rate(price: (buying + selling) / 2, changePercent: entry["Change"] as? Double)
        }

        return (rate("USD"), rate("EUR"), rate("GRA"))
    }
}
