using System.Diagnostics;

namespace Tests;

/// <summary>
/// BDD schema scenarios: golden protoc bytes, generated classes.
/// The case table (BddSchemas.cs, generated from
/// the schema scenarios) carries protoc's own --encode output
/// over webapp/testdata/{kitchen,features}.proto. Each case
/// decodes with the generated classes and re-encodes
/// byte-identically. The generated-classes harness mirrors
/// TestPbMessages.
/// </summary>
public static class TestBddSchemas
{
    private const string Harness = """
        using System;
        using Kitchen.v1;
        using Feat.v1;
        using KitchenT = Kitchen.v1.Kitchen;

        public static class Harness
        {
            public static int Main(string[] args)
            {
                string[][] cases = new string[][] {
        CASESROWS
                };
                foreach (var c in cases)
                {
                    byte[] input = Convert.FromHexString(c[2]);
                    byte[] got;
                    switch (c[1])
                    {
                        case "kitchen":
                        {
                            var m = new KitchenT();
                            m.UnmarshalDc(input);
                            got = m.MarshalDc();
                            break;
                        }
                        case "outer":
                        {
                            var m = new Outer();
                            m.UnmarshalDc(input);
                            got = m.MarshalDc();
                            break;
                        }
                        default:
                            Console.WriteLine("FAIL: unknown message " + c[1]);
                            return 1;
                    }
                    if (Convert.ToHexString(got).ToLowerInvariant() != c[3])
                    {
                        Console.WriteLine("FAIL: re-encode mismatch: " + c[0]);
                        return 1;
                    }
                }
                Console.WriteLine("schemas OK");
                return 0;
            }
        }
        """;

    public static void Run()
    {
        string root = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", ".."));
        if (!File.Exists(Path.Combine(root, "webapp", "testdata", "kitchen.proto")))
        {
            root = Directory.GetCurrentDirectory();
            if (!File.Exists(Path.Combine(root, "webapp", "testdata", "kitchen.proto")))
            {
                root = Path.GetFullPath(Path.Combine(root, ".."));
            }
        }
        string testdata = Path.Combine(root, "webapp", "testdata");
        string tmp = Path.Combine(Path.GetTempPath(), "grpcdc-cs-schemas-" + Guid.NewGuid().ToString("N"));
        string gen = Path.Combine(tmp, "gen");
        Directory.CreateDirectory(gen);
        RunCmd("protoc", testdata,
            "--plugin=protoc-gen-grpc-dc-csharp=" + Path.Combine(root, "bin", "protoc-gen-grpc-dc-csharp"),
            "--grpc-dc-csharp_out=" + gen,
            "-I", testdata, "common.proto", "kitchen.proto", "features.proto");
        File.Delete(Path.Combine(gen, "CommonGrpcDc.cs"));
        File.Delete(Path.Combine(gen, "KitchenGrpcDc.cs"));
        File.Delete(Path.Combine(gen, "FeaturesGrpcDc.cs"));

        var rows = string.Join("\n", BddSchemas.Cases.Select(c =>
            $"            new[] {{ \"{c.Name}\", \"{c.Message}\", \"{c.Input}\", \"{c.Expect}\" }},"));
        File.WriteAllText(Path.Combine(gen, "Harness.cs"), Harness.Replace("CASESROWS", rows));
        File.WriteAllText(Path.Combine(gen, "harness.csproj"), """
            <Project Sdk="Microsoft.NET.Sdk">
              <PropertyGroup>
                <OutputType>Exe</OutputType>
                <TargetFramework>net8.0</TargetFramework>
                <Nullable>disable</Nullable>
              </PropertyGroup>
              <ItemGroup>
                <ProjectReference Include="GRPREF" />
              </ItemGroup>
            </Project>
            """.Replace("GRPREF", Path.Combine(root, "csharp", "grpcdc", "Grpcdc.csproj")));
        RunCmd("dotnet", gen, "run", "--project", "harness.csproj");
        Console.WriteLine("TestBddSchemas OK");
    }

    private static void RunCmd(string file, string dir, params string[] args)
    {
        var psi = new ProcessStartInfo(file)
        {
            WorkingDirectory = dir,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var a in args)
        {
            psi.ArgumentList.Add(a);
        }
        using var p = Process.Start(psi)!;
        string outp = p.StandardOutput.ReadToEnd();
        string err = p.StandardError.ReadToEnd();
        p.WaitForExit();
        if (p.ExitCode != 0 || outp.Contains("FAIL"))
        {
            throw new Exception($"command failed: {file} {string.Join(" ", args)}\n{outp}\n{err}");
        }
        Console.Write(outp);
    }
}
