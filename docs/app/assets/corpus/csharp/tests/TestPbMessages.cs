using System.Diagnostics;

namespace Tests;

/// <summary>
/// Generated C# message types (one class per message) from the
/// native protoc-gen-grpc-dc-csharp plugin: kitchen-sink
/// round-trip plus a protoc oracle — protoc's own --encode bytes
/// must decode to the same message and re-encode identically.
/// </summary>
public static class TestPbMessages
{
    private const string KitchenText = """
        d: 1.5 f: 2.5 i32: -3 i64: -4 u32: 5 u64: 6 s32: -7 s64: -8
        f32: 9 f64: 10 sf32: -11 sf64: -12 flag: true name: "sink"
        blob: "\x01\x02\x03" color: GREEN
        nested { note: "n" level: 3 }
        item { sku: "abc" quantity: 2 }
        nums: [1, -2, 300] words: ["a", "", "bc"]
        manys { note: "m" level: 1 }
        vals: [0.5, -1.25]
        counts { key: "x" value: 1 } counts { key: "y" value: -2 }
        by_id { key: 7 value { note: "z" level: 9 } }
        text: "chosen" big_negative: -9007199254740993 neg32: -123456
        """;

    private const string Harness = """
        using System;
        using System.Collections.Generic;
        using System.IO;
        using Kitchen.v1;
        using Shop.common;
        using KitchenT = Kitchen.v1.Kitchen;

        public static class Harness
        {
            public static int Main(string[] args)
            {
                var k = new KitchenT
                {
                    D = 1.5, F = 2.5f, I32 = -3, I64 = -4, U32 = 5, U64 = 6, S32 = -7, S64 = -8,
                    F32 = 9, F64 = 10, Sf32 = -11, Sf64 = -12, Flag = true, Name = "sink",
                    Blob = new byte[] { 1, 2, 3 }, Color = Color.GREEN,
                    Nested = new Nested { Note = "n", Level = 3 },
                    Item = new Item { Sku = "abc", Quantity = 2 },
                    Nums = new List<int> { 1, -2, 300 },
                    Words = new List<string> { "a", "", "bc" },
                    Manys = new List<Nested> { new Nested { Note = "m", Level = 1 } },
                    Vals = new List<double> { 0.5, -1.25 },
                    Counts = new Dictionary<string, int> { ["x"] = 1, ["y"] = -2 },
                    ById = new Dictionary<long, Nested> { [7] = new Nested { Note = "z", Level = 9 } },
                    Text = "chosen", BigNegative = -9007199254740993L, Neg32 = -123456,
                };
                if (args[0] == "roundtrip")
                {
                    var back = new KitchenT();
                    back.UnmarshalDc(k.MarshalDc());
                    CheckSame(back, k);
                    if (new KitchenT().MarshalDc().Length != 0) Fail("empty must encode empty");
                    var both = new KitchenT { Text = "a", Code = 7 };
                    var bothBack = new KitchenT();
                    bothBack.UnmarshalDc(both.MarshalDc());
                    if (bothBack.Text != "" || bothBack.Code != 7) Fail("oneof encode clearing");
                    Console.WriteLine("roundtrip OK");
                    return 0;
                }
                var protocBytes = File.ReadAllBytes(args[1]);
                var fromProtoc = new KitchenT();
                fromProtoc.UnmarshalDc(protocBytes);
                CheckSame(fromProtoc, k);
                var again = new KitchenT();
                again.UnmarshalDc(fromProtoc.MarshalDc());
                CheckSame(again, fromProtoc);
                Console.WriteLine("oracle OK");
                return 0;
            }

            static void CheckSame(KitchenT a, KitchenT b)
            {
                bool ok = a.D == b.D && a.F == b.F && a.I32 == b.I32 && a.I64 == b.I64
                    && a.U32 == b.U32 && a.U64 == b.U64 && a.S32 == b.S32 && a.S64 == b.S64
                    && a.F32 == b.F32 && a.F64 == b.F64 && a.Sf32 == b.Sf32 && a.Sf64 == b.Sf64
                    && a.Flag == b.Flag && a.Name == b.Name
                    && Convert.ToHexString(a.Blob) == Convert.ToHexString(b.Blob)
                    && a.Color == b.Color
                    && a.Nested.Note == b.Nested.Note && a.Nested.Level == b.Nested.Level
                    && a.Item.Sku == b.Item.Sku && a.Item.Quantity == b.Item.Quantity
                    && string.Join(",", a.Nums) == string.Join(",", b.Nums)
                    && string.Join(",", a.Words) == string.Join(",", b.Words)
                    && a.Manys[0].Note == b.Manys[0].Note
                    && string.Join(",", a.Vals) == string.Join(",", b.Vals)
                    && a.Counts["x"] == b.Counts["x"] && a.Counts["y"] == b.Counts["y"]
                    && a.ById[7].Note == b.ById[7].Note
                    && a.Text == b.Text && a.BigNegative == b.BigNegative && a.Neg32 == b.Neg32;
                if (!ok) Fail("mismatch");
            }

            static void Fail(string msg)
            {
                Console.WriteLine("FAIL: " + msg);
                Environment.Exit(1);
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
        string tmp = Path.Combine(Path.GetTempPath(), "grpcdc-cs-pb-" + Guid.NewGuid().ToString("N"));
        string gen = Path.Combine(tmp, "gen");
        Directory.CreateDirectory(gen);
        RunCmd("protoc", testdata,
            "--plugin=protoc-gen-grpc-dc-csharp=" + Path.Combine(root, "bin", "protoc-gen-grpc-dc-csharp"),
            "--grpc-dc-csharp_out=" + gen,
            "-I", testdata, "common.proto", "kitchen.proto");
        File.Delete(Path.Combine(gen, "CommonGrpcDc.cs"));
        File.Delete(Path.Combine(gen, "KitchenGrpcDc.cs"));
        File.WriteAllText(Path.Combine(gen, "Harness.cs"), Harness);
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
        RunCmd("dotnet", gen, "run", "--project", "harness.csproj", "--", "roundtrip");
        byte[] protocBytes = ProtocEncode(testdata);
        string bin = Path.Combine(tmp, "protoc.bin");
        File.WriteAllBytes(bin, protocBytes);
        RunCmd("dotnet", gen, "run", "--project", "harness.csproj", "--", "oracle", bin);
        Console.WriteLine("TestPbMessages OK");
    }

    private static byte[] ProtocEncode(string testdata)
    {
        var psi = new ProcessStartInfo("protoc")
        {
            WorkingDirectory = testdata,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        psi.ArgumentList.Add("--encode=kitchen.v1.Kitchen");
        psi.ArgumentList.Add("-I");
        psi.ArgumentList.Add(testdata);
        psi.ArgumentList.Add("kitchen.proto");
        using var p = Process.Start(psi)!;
        p.StandardInput.Write(KitchenText);
        p.StandardInput.Close();
        using var ms = new MemoryStream();
        p.StandardOutput.BaseStream.CopyTo(ms);
        p.WaitForExit();
        Program.Check(p.ExitCode == 0, "protoc --encode");
        return ms.ToArray();
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
