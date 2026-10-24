package tests;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;

/// BDD schema scenarios: golden protoc bytes, generated classes.
/// The case table (tests.BddSchemas, generated from
/// the schema scenarios) carries protoc's own --encode output
/// over webapp/testdata/{kitchen,features}.proto. Each case
/// decodes with the generated classes and re-encodes
/// byte-identically. The generated-classes harness mirrors
/// TestPbMessages.
public final class TestBddSchemas {

    private static String harnessRows() {
        StringBuilder sb = new StringBuilder();
        for (BddSchemas.Case c : BddSchemas.CASES) {
            sb.append("        {\"")
                    .append(c.name()).append("\", \"")
                    .append(c.message()).append("\", \"")
                    .append(c.input()).append("\", \"")
                    .append(c.expect()).append("\"},\n");
        }
        return sb.toString();
    }

    private static final String HARNESS_HEAD = """
            import java.util.HexFormat;
            import kitchen.v1.Kitchen;
            import feat.v1.Outer;

            public final class Harness {
                public static void main(String[] args) {
                    String[][] cases = {
            """;

    private static final String HARNESS_TAIL = """
                    };
                    for (String[] c : cases) {
                        byte[] input = HexFormat.of().parseHex(c[2]);
                        byte[] got;
                        switch (c[1]) {
                            case "kitchen" -> {
                                Kitchen m = new Kitchen();
                                m.unmarshalDc(input);
                                got = m.marshalDc();
                            }
                            case "outer" -> {
                                Outer m = new Outer();
                                m.unmarshalDc(input);
                                got = m.marshalDc();
                            }
                            default -> throw new AssertionError("unknown message " + c[1]);
                        }
                        if (!HexFormat.of().formatHex(got).equals(c[3])) {
                            System.out.println("FAIL: re-encode mismatch: " + c[0]);
                            System.exit(1);
                        }
                    }
                    System.out.println("schemas OK");
                }
            }
            """;

    private static void run(List<String> cmd, Path dir) throws Exception {
        ProcessBuilder pb = new ProcessBuilder(cmd).directory(dir.toFile());
        pb.redirectErrorStream(true);
        Process p = pb.start();
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

    public static void main(String[] args) throws Exception {
        Path root = Path.of("..").toAbsolutePath().normalize();
        if (!Files.exists(root.resolve("webapp/testdata/kitchen.proto"))) {
            root = Path.of(".").toAbsolutePath().normalize();
        }
        Path testdata = root.resolve("webapp/testdata");
        Path tmp = Files.createTempDirectory("grpcdc-java-schemas-");
        Path gen = Files.createDirectories(tmp.resolve("gen"));
        run(List.of("protoc",
                "--plugin=protoc-gen-grpc-dc-java=" + root.resolve("bin/protoc-gen-grpc-dc-java"),
                "--grpc-dc-java_out=" + gen,
                "-I", testdata.toString(), "common.proto", "kitchen.proto", "features.proto"), testdata);
        Files.delete(gen.resolve("CommonGrpcDc.java"));
        Files.delete(gen.resolve("KitchenGrpcDc.java"));
        Files.delete(gen.resolve("FeaturesGrpcDc.java"));

        Path classes = Files.createDirectories(tmp.resolve("classes"));
        List<String> javac = new ArrayList<>(List.of("javac", "-d", classes.toString()));
        try (var stream = Files.walk(gen)) {
            stream.filter(p -> p.toString().endsWith(".java")).forEach(p -> javac.add(p.toString()));
        }
        javac.add(root.resolve("java/grpcdc/Marshaler.java").toString());
        javac.add(root.resolve("java/grpcdc/Unmarshaler.java").toString());
        Path harness = gen.resolve("Harness.java");
        Files.writeString(harness, HARNESS_HEAD + harnessRows() + HARNESS_TAIL);
        javac.add(harness.toString());
        run(javac, tmp);
        run(List.of("java", "-cp", classes.toString(), "Harness"), tmp);
        System.out.println("TestBddSchemas OK");
    }
}
