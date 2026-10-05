import Foundation

struct AppConfiguration: Sendable {
    let supabaseURL: URL?
    let supabaseAnonKey: String?

    static var current: AppConfiguration {
        let info = Bundle.main.infoDictionary ?? [:]
        let urlString = info["SUPABASE_URL"] as? String
        let key = info["SUPABASE_ANON_KEY"] as? String
        return AppConfiguration(
            supabaseURL: urlString.flatMap(URL.init(string:)),
            supabaseAnonKey: key?.isEmpty == false ? key : nil
        )
    }
}
