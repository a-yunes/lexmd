import Foundation

/// "1 word", "2 words", "1,234 words": a count with its noun in the matching form.
func counted(_ count: Int, _ singular: String, plural: String? = nil) -> String {
    "\(count.formatted()) \(count == 1 ? singular : plural ?? singular + "s")"
}
