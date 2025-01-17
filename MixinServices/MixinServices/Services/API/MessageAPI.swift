import UIKit
import Alamofire

public class MessageAPI: BaseAPI {
    
    public static let shared = MessageAPI()
    
    private enum url {
        
        static let attachments = "attachments"
        static func attachments(id: String) -> String {
            return "attachments/\(id)"
        }
        
        static let acknowledge = "messages/acknowledge"
        
        static func messageStatus(offset: Int64) -> String {
            return "messages/status/\(offset)"
        }
        
        static let acknowledgements = "acknowledgements"
    }
    
    public func acknowledgements(ackMessages: [AckMessage]) -> BaseAPI.Result<Empty> {
        let parameters = ackMessages.map({ ["message_id": $0.messageId, "status": $0.status] }).toParameters()
        return request(method: .post, url: url.acknowledgements, parameters: parameters, encoding: JSONArrayEncoding())
    }
    
    public func messageStatus(offset: Int64) -> BaseAPI.Result<[BlazeMessageData]> {
        return request(method: .get, url: url.messageStatus(offset: offset))
    }
    
    public func requestAttachment() -> BaseAPI.Result<AttachmentResponse> {
        return request(method: .post, url: url.attachments)
    }
    
    public func getAttachment(id: String) -> BaseAPI.Result<AttachmentResponse> {
        return request(method: .get, url: url.attachments(id: id))
    }
    
}
