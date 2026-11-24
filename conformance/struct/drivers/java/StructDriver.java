import shapes.*;

public class StructDriver {
    static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder();
        for (byte x : b) sb.append(String.format("%02x", x));
        return sb.toString();
    }

    static byte[] unhex(String s) {
        byte[] b = new byte[s.length() / 2];
        for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16);
        return b;
    }

    public static void main(String[] args) {
        Outer m = new Outer();
        m.inner = new Inner(); m.inner.v = "x"; m.inner.n = -3;
        m.hue = Hue.RED;
        m.nums = new java.util.ArrayList<>(java.util.List.of(1, -2, 300));
        m.byName = new java.util.HashMap<>();
        m.byName.put("b", new Inner()); m.byName.get("b").v = "second";
        m.byName.put("a", new Inner()); m.byName.get("a").v = "first"; m.byName.get("a").n = 9;
        m.s = "picked";
        m.blob = new byte[]{1, 2, 3};
        m.names = new java.util.ArrayList<>(java.util.List.of("n1", "n2"));
        m.inners = new java.util.ArrayList<>();
        Inner i1 = new Inner(); i1.v = "i1"; m.inners.add(i1);
        Inner i2 = new Inner(); i2.v = "i2"; m.inners.add(i2);
        Inner i3 = new Inner(); i3.v = "i3"; m.inners.add(i3);
        m.byId = new java.util.HashMap<>();
        m.byId.put(7, "seven"); m.byId.put(2, "two");
        m.score = 3.5; m.ratio = 0.25f; m.flag = true; m.stamp = 123456789L; m.delta = -77;
        byte[] bytes = OuterStruct.marshal(m);
        System.out.println("MARSHAL " + hex(bytes));
        Outer back = OuterStruct.unmarshal(unhex(args[0]));
        if (!back.byName.get("a").v.equals("first") || back.score != 3.5 || back.delta != -77
                || !back.s.equals("picked") || !back.byId.get(7).equals("seven")) {
            System.out.println("DECODE_MISMATCH");
            return;
        }
        System.out.println("DECODE_OK");
        // Proto2 shape (msgs2.proto / golden2).
        P2 p2 = new P2();
        p2.name = "req"; p2.count = 42; p2.greeting = "hi"; p2.enabled = false;
        p2.ratio = 2.5; p2.nums = new java.util.ArrayList<>(java.util.List.of(5, -6));
        p2.extNote = "note!";
        byte[] golden2 = unhex(args[1]);
        byte[] got2 = P2Struct.marshal(p2);
        if (!java.util.Arrays.equals(got2, golden2)) {
            System.out.println("P2_MARSHAL_MISMATCH\n got " + hex(got2) + "\nwant " + args[1]);
            System.exit(1);
        }
        // Decode into a zero-value message: P2Struct.unmarshal applies
        // proto2 defaults for absent fields, so restore zero values for
        // fields the struct presence bitmap marks absent (enabled=false
        // here) before re-marshalling, or defaults would manufacture presence.
        P2 back2 = P2Struct.unmarshal(golden2);
        int presence = (golden2[12] & 0xFF) | ((golden2[13] & 0xFF) << 8)
                | ((golden2[14] & 0xFF) << 16) | ((golden2[15] & 0xFF) << 24);
        if ((presence & (1 << 0)) == 0) back2.name = "";
        if ((presence & (1 << 1)) == 0) back2.count = 0;
        if ((presence & (1 << 2)) == 0) back2.greeting = "";
        if ((presence & (1 << 3)) == 0) back2.enabled = false;
        if ((presence & (1 << 4)) == 0) back2.ratio = 0;
        if ((presence & (1 << 5)) == 0) back2.nums = new java.util.ArrayList<>();
        if (!java.util.Arrays.equals(P2Struct.marshal(back2), golden2)) {
            System.out.println("P2_ROUNDTRIP_MISMATCH");
            System.exit(1);
        }
        System.out.println("P2_DECODE_OK");
    }
}
