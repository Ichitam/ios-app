import MixinServices

final class ContactAPI: BaseAPI {

    static let shared = ContactAPI()

    enum url {
        static let contacts = "friends"
    }

    func syncContacts() {
        request(method: .get, url: url.contacts) { (result: BaseAPI.Result<[UserResponse]>) in
            switch result {
            case let .success(contacts):
                UserDAO.shared.updateUsers(users: contacts, notifyContact: true)
            case .failure:
                break
            }
        }
    }

}


