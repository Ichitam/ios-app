import Foundation

public var myUserId: String {
    LoginManager.shared.account?.user_id ?? ""
}

public var myIdentityNumber: String {
    LoginManager.shared.account?.identity_number ?? "00000"
}

public final class LoginManager {
    
    public static let shared = LoginManager()
    public static let accountDidChangeNotification = Notification.Name("one.mixin.services.account.did.change")
    public static let didLogoutNotification = Notification.Name("one.mixin.services.did.logout")

    fileprivate var _account: Account?
    fileprivate var _isLoggedIn = false
    fileprivate var lock = pthread_rwlock_t()

    public var isLoggedIn: Bool {
        pthread_rwlock_rdlock(&lock)
        let loggedIn = _isLoggedIn
        pthread_rwlock_unlock(&lock)
        return loggedIn
    }
    
    public var account: Account? {
        pthread_rwlock_rdlock(&lock)
        let account = _account
        pthread_rwlock_unlock(&lock)
        return account
    }
    
    private init() {
        pthread_rwlock_init(&lock, nil)
        _account = LoginManager.getAccountFromUserDefaults()
        _isLoggedIn = _account != nil && !(AppGroupUserDefaults.Account.sessionSecret?.isEmpty ?? true)
    }

    fileprivate static func getAccountFromUserDefaults() -> Account? {
        guard let data = AppGroupUserDefaults.Account.serializedAccount else {
            return nil
        }

        return try? JSONDecoder.default.decode(Account.self, from: data)
    }

    public func reloadAccountFromUserDefaults() {
        pthread_rwlock_wrlock(&lock)
        _account = LoginManager.getAccountFromUserDefaults()
        _isLoggedIn = _account != nil && !(AppGroupUserDefaults.Account.sessionSecret?.isEmpty ?? true)
        pthread_rwlock_unlock(&lock)
    }
    
    public func setAccount(_ account: Account?, updateUserTable: Bool = true) {
        pthread_rwlock_wrlock(&lock)
        _account = account
        _isLoggedIn = _account != nil && !(AppGroupUserDefaults.Account.sessionSecret?.isEmpty ?? true)
        pthread_rwlock_unlock(&lock)

        if let account = account {
            if let data = try? JSONEncoder.default.encode(account) {
                AppGroupUserDefaults.Account.serializedAccount = data
            }
            NotificationCenter.default.post(name: LoginManager.accountDidChangeNotification, object: self)
            if updateUserTable {
                DispatchQueue.global().async {
                    UserDAO.shared.updateAccount(account: account)
                }
            }
        } else {
            AppGroupUserDefaults.Account.serializedAccount = nil
        }
    }
    
    public func logout(from: String) {
        guard account != nil else {
            return
        }

        pthread_rwlock_wrlock(&lock)
        _account = nil
        _isLoggedIn = false
        pthread_rwlock_unlock(&lock)

        if !isAppExtension {
            Logger.write(log: "===========logout...from:\(from)")
            AppGroupUserDefaults.Account.serializedAccount = nil
            AppGroupUserDefaults.User.isLogoutByServer = true
            DispatchQueue.main.async {
                Keychain.shared.clearPIN()
                WebSocketService.shared.disconnect()
                AppGroupUserDefaults.Account.clearAll()
                SignalDatabase.shared.logout()
                NotificationCenter.default.post(name: LoginManager.didLogoutNotification, object: self)
            }
        }
    }

}

