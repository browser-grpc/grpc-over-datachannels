import Foundation

// Test runner: ./tests <TestCodec|TestEcho|TestInterop|TestOracle|TestDynamic|TestBdd|TestDeadline|TestInlinePump>
let args = CommandLine.arguments
if args.count < 2 {
    FileHandle.standardError.write("usage: tests <TestCodec|TestEcho|TestInterop|TestOracle|TestDynamic|TestBdd|TestDeadline|TestInlinePump>\n".data(using: .utf8)!)
    exit(2)
}
do {
    switch args[1] {
    case "TestCodec": try TestCodec()
    case "TestEcho": try TestEcho()
    case "TestInterop": try TestInterop()
    case "TestOracle": try TestOracle()
    case "TestDynamic": try TestDynamic()
    case "TestBdd": try TestBdd()
    case "TestDeadline": try TestDeadline()
    case "TestInlinePump": try TestInlinePump()
    case "TestPbMessages": try TestPbMessages()
    case "TestBddSchemas": try TestBddSchemas()
    case "TestSidecar": try TestSidecar()
    default:
        FileHandle.standardError.write("unknown test: \(args[1])\n".data(using: .utf8)!)
        exit(2)
    }
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
