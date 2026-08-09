import Darwin
import Foundation
import PutioHarnessKit

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  let invocation = try HarnessArgumentParser.parse(arguments)
  let context = try RepositoryContext.discover()
  let response = try HarnessService(context: context).execute(invocation)
  print(try HarnessOutput.render(response, format: HarnessOutput.format(for: invocation)))
  if case .doctor(let report) = response, report.status != "ok" {
    exit(1)
  }
} catch {
  let json = CommandLine.arguments.contains("json") && CommandLine.arguments.contains("--output")
  FileHandle.standardError.write(Data((HarnessOutput.error(error, json: json) + "\n").utf8))
  exit(2)
}
