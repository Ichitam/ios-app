import UIKit

public class Currency: CustomDebugStringConvertible {
    
    public let code: String
    public let symbol: String
    public var rate: Double
    
    public var icon: UIImage {
        return UIImage(named: "CurrencyIcon/\(code)")!
    }
    
    init(code: String, symbol: String, rate: Double) {
        self.code = code
        self.symbol = symbol
        self.rate = rate
    }
    
    public var debugDescription: String {
        return "<Currency: \(Unmanaged.passUnretained(self).toOpaque()), code: \(code), symbol: \(symbol), rate: \(rate)>"
    }
    
}

public extension Currency {
    
    static let currentCurrencyDidChangeNotification = Notification.Name(rawValue: "one.mixin.services.current.currency.did.change")
    
    private(set) static var current = currentCurrencyStorage {
        didSet {
            NotificationCenter.default.post(name: currentCurrencyDidChangeNotification, object: nil)
        }
    }
    
    private(set) static var all: [Currency] = {
        let currencies = [
            Currency(code: "USD", symbol: "$", rate: 1),
            Currency(code: "CNY", symbol: "¥", rate: 7.159817),
            Currency(code: "JPY", symbol: "¥", rate: 106.1796608),
            Currency(code: "EUR", symbol: "€", rate: 0.909926),
            Currency(code: "KRW", symbol: "₩", rate: 1210.86),
            Currency(code: "HKD", symbol: "HK$", rate: 7.842744),
            Currency(code: "GBP", symbol: "£", rate: 0.821636),
            Currency(code: "AUD", symbol: "A$", rate: 1.485802),
            Currency(code: "SGD", symbol: "S$", rate: 1.389179),
            Currency(code: "MYR", symbol: "RM", rate: 4.205481)
        ]
        let rates = AppGroupUserDefaults.currencyRates
        for currency in currencies {
            guard let rate = rates[currency.code] else {
                continue
            }
            currency.rate = rate
        }
        return currencies
    }()
    
    private static var map = [String: Currency](uniqueKeysWithValues: all.map({ ($0.code, $0) }))
    private static var currentCurrencyStorage: Currency {
        if let code = LoginManager.shared.account?.fiat_currency, let currency = map[code] {
            return currency
        } else {
            return all[0] // USD for default
        }
    }

    static func refreshCurrentCurrency() {
        current = currentCurrencyStorage
    }
    
    static func updateRate(with monies: [FiatMoney]) {
        for money in monies {
            map[money.code]?.rate = money.rate
        }
        let rates = map.mapValues({ $0.rate })
        AppGroupUserDefaults.currencyRates = rates
    }
    
}
