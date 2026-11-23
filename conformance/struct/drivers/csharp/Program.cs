using System;
using Shapes;

public static class Program {
    static Outer Build() {
        var m = new Outer();
        m.Inner = new Inner { V = "x", N = -3 };
        m.Hue = Hue.RED;
        m.Nums = new System.Collections.Generic.List<int> { 1, -2, 300 };
        m.ByName = new System.Collections.Generic.Dictionary<string, Inner> {
            ["b"] = new Inner { V = "second" },
            ["a"] = new Inner { V = "first", N = 9 },
        };
        m.S = "picked";
        m.Blob = new byte[] { 1, 2, 3 };
        m.Names = new System.Collections.Generic.List<string> { "n1", "n2" };
        m.Inners = new System.Collections.Generic.List<Inner> {
            new Inner { V = "i1" }, new Inner { V = "i2" }, new Inner { V = "i3" } };
        m.ById = new System.Collections.Generic.Dictionary<int, string> {
            [7] = "seven", [2] = "two" };
        m.Score = 3.5;
        m.Ratio = 0.25f;
        m.Flag = true;
        m.Stamp = 123456789UL;
        m.Delta = -77;
        return m;
    }

    static P2 BuildP2() {
        var m = new P2();
        m.Name = "req";
        m.Count = 42;
        m.Greeting = "hi";
        m.Enabled = false;
        m.Ratio = 2.5;
        m.Nums = new System.Collections.Generic.List<int> { 5, -6 };
        m.ExtNote = "note!";
        return m;
    }

    static string Hex(byte[] b) {
        var sb = new System.Text.StringBuilder();
        foreach (var x in b) sb.Append(x.ToString("x2"));
        return sb.ToString();
    }

    public static int Main(string[] args) {
        var goldenHex = args[0];
        var golden = new byte[goldenHex.Length / 2];
        for (var i = 0; i < golden.Length; i++)
            golden[i] = Convert.ToByte(goldenHex.Substring(2 * i, 2), 16);
        var got = OuterStruct.Marshal(Build());
        if (Hex(got) != goldenHex) {
            Console.WriteLine("MARSHAL_MISMATCH\n got " + Hex(got) + "\nwant " + goldenHex);
            return 1;
        }
        var back = OuterStruct.Unmarshal(golden);
        if (Hex(OuterStruct.Marshal(back)) != goldenHex) {
            Console.WriteLine("ROUNDTRIP_MISMATCH");
            return 1;
        }
        var golden2Hex = args[1];
        var golden2 = new byte[golden2Hex.Length / 2];
        for (var i = 0; i < golden2.Length; i++)
            golden2[i] = Convert.ToByte(golden2Hex.Substring(2 * i, 2), 16);
        var got2 = P2Struct.Marshal(BuildP2());
        if (Hex(got2) != golden2Hex) {
            Console.WriteLine("MARSHAL2_MISMATCH\n got " + Hex(got2) + "\nwant " + golden2Hex);
            return 1;
        }
        var back2 = P2Struct.Unmarshal(golden2);
        if (Hex(P2Struct.Marshal(back2)) != golden2Hex) {
            Console.WriteLine("ROUNDTRIP2_MISMATCH");
            return 1;
        }
        Console.WriteLine("DECODE_OK");
        return 0;
    }
}
