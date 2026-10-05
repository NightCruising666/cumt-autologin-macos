// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct BackendResult: Decodable {
    let state: String
    let message: String
    let retry_delay: Double?
}

enum AppError: Error {
    case message(String)
    var description: String {
        switch self { case .message(let value): return value }
    }
}
