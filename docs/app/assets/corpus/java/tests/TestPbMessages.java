package tests;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * Generated Java message types (one class per message) from the
 * native protoc-gen-grpc-dc-java plugin: kitchen-sink round-trip
 * plus a protoc oracle — protoc's own --encode bytes must decode
 * to the same message and re-encode semantically identically.
 */
public final class TestPbMessages {
    private TestPbMessages() {}

    private static final String KITCHEN_TEXT = """
            d: 1.5 f: 2.5 i32: -3 i64: -4 u32: 5 u64: 6 s32: -7 s64: -8
            f32: 9 f64: 10 sf32: -11 sf64: -12 flag: true name: "sink"
            blob: "\\x01\\x02\\x03" color: GREEN
            nested { note: "n" level: 3 }
            item { sku: "abc" quantity: 2 }
            nums: [1, -2, 300] words: ["a", "", "bc"]
            manys { note: "m" level: 1 }
            vals: [0.5, -1.25]
            counts { key: "x" value: 1 } counts { key: "y" value: -2 }
            by_id { key: 7 value { note: "z" level: 9 } }
            text: "chosen" big_negative: -9007199254740993 neg32: -123456
            """;

    private static final String HARNESS = """
            import java.nio.file.Files;
            import java.nio.file.Path;
            import java.util.List;
            import java.util.Map;
            import kitchen.v1.Color;
            import kitchen.v1.Kitchen;
            import kitchen.v1.Nested;
            import shop.common.Item;

            public final class Harness {
                public static void main(String[] args) throws Exception {
                    Kitchen k = new Kitchen();
                    k.d = 1.5; k.f = 2.5f; k.i32 = -3; k.i64 = -4; k.u32 = 5; k.u64 = 6;
                    k.s32 = -7; k.s64 = -8; k.f32 = 9; k.f64 = 10; k.sf32 = -11; k.sf64 = -12;
                    k.flag = true; k.name = "sink"; k.blob = new byte[] {1, 2, 3};
                    k.color = Color.GREEN;
                    Nested nested = new Nested(); nested.note = "n"; nested.level = 3;
                    k.nested = nested;
                    Item item = new Item(); item.sku = "abc"; item.quantity = 2;
                    k.item = item;
                    k.nums = List.of(1, -2, 300);
                    k.words = List.of("a", "", "bc");
                    Nested m = new Nested(); m.note = "m"; m.level = 1;
                    k.manys = List.of(m);
                    k.vals = List.of(0.5, -1.25);
                    k.counts = Map.of("x", 1, "y", -2);
                    Nested z = new Nested(); z.note = "z"; z.level = 9;
                    k.byId = Map.of(7L, z);
                    k.text = "chosen"; k.bigNegative = -9007199254740993L; k.neg32 = -123456;

                    if (args[0].equals("roundtrip")) {
                        Kitchen back = new Kitchen();
                        back.unmarshalDc(k.marshalDc());
                        checkSame(back, k);
                        if (new Kitchen().marshalDc().length != 0) fail("empty must encode empty");
                        Kitchen both = new Kitchen();
                        both.text = "a"; both.code = 7;
                        Kitchen bothBack = new Kitchen();
                        bothBack.unmarshalDc(both.marshalDc());
                        if (!bothBack.text.equals("") || bothBack.code != 7) fail("oneof encode clearing");
                        System.out.println("roundtrip OK");
                        return;
                    }
                    byte[] protocBytes = Files.readAllBytes(Path.of(args[1]));
                    Kitchen fromProtoc = new Kitchen();
                    fromProtoc.unmarshalDc(protocBytes);
                    checkSame(fromProtoc, k);
                    Kitchen again = new Kitchen();
                    again.unmarshalDc(fromProtoc.marshalDc());
                    checkSame(again, fromProtoc);
                    System.out.println("oracle OK");
                }

                static void checkSame(Kitchen a, Kitchen b) {
                    if (a.d != b.d || a.f != b.f || a.i32 != b.i32 || a.i64 != b.i64
                            || a.u32 != b.u32 || a.u64 != b.u64 || a.s32 != b.s32 || a.s64 != b.s64
                            || a.f32 != b.f32 || a.f64 != b.f64 || a.sf32 != b.sf32 || a.sf64 != b.sf64
                            || a.flag != b.flag || !a.name.equals(b.name)
                            || !java.util.Arrays.equals(a.blob, b.blob) || a.color != b.color
                            || !a.nested.note.equals(b.nested.note) || a.nested.level != b.nested.level
                            || !a.item.sku.equals(b.item.sku) || a.item.quantity != b.item.quantity
                            || !a.nums.equals(b.nums) || !a.words.equals(b.words)
                            || a.manys.size() != b.manys.size() || !a.manys.get(0).note.equals(b.manys.get(0).note)
                            || !a.vals.equals(b.vals) || !a.counts.equals(b.counts)
                            || !a.byId.get(7L).note.equals(b.byId.get(7L).note)
                            || !a.text.equals(b.text) || a.bigNegative != b.bigNegative || a.neg32 != b.neg32) {
                        fail("mismatch");
                    }
                }

                static void fail(String msg) {
                    System.out.println("FAIL: " + msg);
                    System.exit(1);
                }
            }
            """;

    private static void run(List<String> cmd, Path dir, String stdin) throws Exception {
        ProcessBuilder pb = new ProcessBuilder(cmd).directory(dir.toFile());
        pb.redirectErrorStream(true);
        Process p = pb.start();
        if (stdin != null) {
            p.getOutputStream().write(stdin.getBytes());
        }
        p.getOutputStream().close();
        String out = new String(p.getInputStream().readAllBytes());
        int code = p.waitFor();
        if (code != 0) {
            throw new AssertionError("command failed " + cmd + "\n" + out);
        }
        if (!out.isBlank() && !out.contains("OK")) {
            System.out.print(out);
        }
    }

    private static byte[] protocEncode(Path testdata) throws Exception {
        ProcessBuilder pb = new ProcessBuilder("protoc", "--encode=kitchen.v1.Kitchen",
                "-I", testdata.toString(), "kitchen.proto").directory(testdata.toFile());
        Process p = pb.start();
        p.getOutputStream().write(KITCHEN_TEXT.getBytes());
        p.getOutputStream().close();
        byte[] out = p.getInputStream().readAllBytes();
        if (p.waitFor() != 0) {
            throw new AssertionError("protoc --encode failed");
        }
        return out;
    }

    public static void main(String[] args) throws Exception {
        Path root = Path.of("..").toAbsolutePath().normalize();
        if (!Files.exists(root.resolve("webapp/testdata/kitchen.proto"))) {
            root = Path.of(".").toAbsolutePath().normalize();
        }
        Path testdata = root.resolve("webapp/testdata");
        Path tmp = Files.createTempDirectory("grpcdc-java-pb-");
        Path gen = Files.createDirectories(tmp.resolve("gen"));
        run(List.of("protoc",
                "--plugin=protoc-gen-grpc-dc-java=" + root.resolve("bin/protoc-gen-grpc-dc-java"),
                "--grpc-dc-java_out=" + gen,
                "-I", testdata.toString(), "common.proto", "kitchen.proto"), testdata, null);
        // Stubs need the grpcdc runtime; test only message classes.
        Files.delete(gen.resolve("CommonGrpcDc.java"));
        Files.delete(gen.resolve("KitchenGrpcDc.java"));

        Path classes = Files.createDirectories(tmp.resolve("classes"));
        List<String> javac = new ArrayList<>(List.of("javac", "-d", classes.toString()));
        List<Path> sources = new ArrayList<>();
        try (var stream = Files.walk(gen)) {
            stream.filter(p -> p.toString().endsWith(".java")).forEach(sources::add);
        }
        sources.add(root.resolve("java/grpcdc/Marshaler.java"));
        sources.add(root.resolve("java/grpcdc/Unmarshaler.java"));
        Path harness = tmp.resolve("Harness.java");
        Files.writeString(harness, HARNESS);
        sources.add(harness);
        for (Path s : sources) {
            javac.add(s.toString());
        }
        run(javac, tmp, null);
        run(List.of("java", "-cp", classes.toString(), "Harness", "roundtrip"), tmp, null);
        Path bin = tmp.resolve("protoc.bin");
        Files.write(bin, protocEncode(testdata));
        run(List.of("java", "-cp", classes.toString(), "Harness", "oracle", bin.toString()), tmp, null);
        System.out.println("TestPbMessages OK");
    }
}
