extension PutioFileActionFailure {
  public init?(restoring item: PutioFileItem, error: Error) {
    self.init(action: .restore(fileID: item.id, name: item.name), error: error)
  }
}
