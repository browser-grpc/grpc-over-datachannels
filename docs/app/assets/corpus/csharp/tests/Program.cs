namespace Tests;

/// <summary>Test runner: dotnet run --project tests -- &lt;TestName&gt;.</summary>
public static class Program
{
    public static int Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("usage: GrpcdcTests <TestCodec|TestEcho|TestInterop|TestOracle|TestDynamic|TestBdd|TestDeadline>");
            return 2;
        }
        try
        {
            switch (args[0])
            {
                case "TestCodec": TestCodec.Run(); break;
                case "TestEcho": TestEcho.Run(); break;
                case "TestInterop": TestInterop.Run(); break;
                case "TestInteropOracle": TestInteropOracle.Run(); break;
                case "TestOracle": TestOracle.Run(); break;
                case "TestDynamic": TestDynamic.Run(); break;
                case "TestBdd": TestBdd.Run(); break;
                case "TestDeadline": TestDeadline.Run(); break;
                case "TestPbMessages": TestPbMessages.Run(); break;
                case "TestBddSchemas": TestBddSchemas.Run(); break;
                case "TestSidecar": TestSidecar.Run(); break;
                default:
                    Console.Error.WriteLine($"unknown test: {args[0]}");
                    return 2;
            }
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine(e);
            return 1;
        }
    }

    public static void Check(bool condition, string what)
    {
        if (!condition)
        {
            throw new Exception($"check failed: {what}");
        }
    }
}
