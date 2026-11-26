extension PutioFileActionFailure {
  public init?(restoring item: PutioFileItem, error: Error) {
    self.init(action: .restore(fileIDs: [item.id]), error: error)
  }
}
