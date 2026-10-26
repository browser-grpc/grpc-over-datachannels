<?php
// Test runner: php php/tests/main.php <TestCodec|TestEcho|TestInterop|TestOracle|TestDynamic|TestBdd|TestFiber|TestDeadline|TestPbMessages|TestBddSchemas>

require_once __DIR__ . "/test_util.php";

$name = $argv[1] ?? null;
if ($name === null) {
    fwrite(STDERR, "usage: main.php <TestCodec|TestEcho|TestInterop|TestOracle|TestDynamic|TestBdd|TestFiber|TestDeadline|TestPbMessages>\n");
    exit(2);
}

try {
    switch ($name) {
        case "TestCodec":
            require_once __DIR__ . "/test_codec.php";
            TestCodec::run();
            break;
        case "TestEcho":
            require_once __DIR__ . "/test_echo.php";
            TestEcho::run();
            break;
        case "TestInterop":
            require_once __DIR__ . "/test_interop.php";
            TestInterop::run();
            break;
        case "TestInteropOracle":
            require_once __DIR__ . "/test_interop_oracle.php";
            TestInteropOracle::run();
            break;
        case "TestOracle":
            require_once __DIR__ . "/test_oracle.php";
            TestOracle::run();
            break;
        case "TestDynamic":
            require_once __DIR__ . "/test_dynamic.php";
            TestDynamic::run();
            break;
        case "TestBdd":
            require_once __DIR__ . "/test_bdd.php";
            TestBdd::run();
            break;
        case "TestFiber":
            require_once __DIR__ . "/test_fiber.php";
            TestFiber::run();
            break;
        case "TestDeadline":
            require_once __DIR__ . "/test_deadline.php";
            TestDeadline::run();
            break;
        case "TestSidecar":
            require_once __DIR__ . "/test_sidecar.php";
            TestSidecar::run();
            break;
        case "TestPbMessages":
            require_once __DIR__ . "/test_pb_messages.php";
            TestPbMessages::run();
            break;
        case "TestBddSchemas":
            require_once __DIR__ . "/test_bdd_schemas.php";
            TestBddSchemas::run();
            break;
        default:
            fwrite(STDERR, "unknown test: $name\n");
            exit(2);
    }
} catch (SkipTest $e) {
    fwrite(STDERR, "SKIP $name: " . $e->getMessage() . "\n");
    exit(0);
} catch (\Throwable $e) {
    fwrite(STDERR, "FAIL $name: " . get_class($e) . ": " . $e->getMessage() . "\n");
    exit(1);
}
