public struct RetentionPolicy: Equatable, Sendable {
    public var textDays: Int
    public var imageDays: Int
    /// A file item is just a path of a few dozen bytes, so there's no reason for it to expire on the
    /// short image cycle; it defaults to the same as text
    public var fileDays: Int

    public init(textDays: Int, imageDays: Int, fileDays: Int) {
        self.textDays = textDays
        self.imageDays = imageDays
        self.fileDays = fileDays
    }

    public static let `default` = RetentionPolicy(textDays: 30, imageDays: 7, fileDays: 30)
}
