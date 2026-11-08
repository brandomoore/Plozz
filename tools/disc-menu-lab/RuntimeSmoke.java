import java.net.SocketPermission;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Original runtime probe, not a disc application or a compatibility suite. */
public final class RuntimeSmoke {
    public static void expectedFailure() {
        throw new IllegalStateException("Expected JNI exception");
    }

    @SuppressWarnings("removal")
    public static int run() throws Exception {
        StorageSmoke.run();
        int sum = 0;
        for (int i = 1; i <= 100; i++) {
            sum += i;
        }
        Path file = Files.createTempFile("plozz-zero-", ".txt");
        try {
            Files.writeString(file, "Zero runtime");
            if (!Files.readString(file).equals("Zero runtime")) {
                throw new AssertionError("Java file round trip failed");
            }
        } finally {
            Files.delete(file);
        }
        byte[] digest = MessageDigest.getInstance("SHA-256")
                .digest("abc".getBytes(StandardCharsets.UTF_8));
        if (!java.util.HexFormat.of().formatHex(digest).equals(
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")) {
            throw new AssertionError("SHA-256 result was incorrect");
        }
        CountDownLatch completed = new CountDownLatch(1);
        Thread worker = new Thread(completed::countDown, "zero-smoke");
        worker.start();
        if (!completed.await(10, TimeUnit.SECONDS)) {
            throw new AssertionError("Java worker did not run");
        }
        worker.join();
        try {
            new ProcessBuilder("/usr/bin/true").start();
            throw new AssertionError("External process creation unexpectedly succeeded");
        } catch (Exception | ExceptionInInitializerError error) {
            Throwable cause = error;
            while (cause.getCause() != null) {
                cause = cause.getCause();
            }
            if (!(cause instanceof UnsupportedOperationException)) {
                throw new AssertionError("Wrong process rejection", error);
            }
        }
        System.setSecurityManager(new SecurityManager());
        try {
            Class.forName("java.io.PlozzStorageBudget").getMethod("begin").invoke(null);
            throw new AssertionError("An active disc reset its budget");
        } catch (java.lang.reflect.InvocationTargetException expected) {
            if (!(expected.getCause() instanceof SecurityException)) throw expected;
        }
        try {
            System.getSecurityManager().checkPermission(
                    new SocketPermission("example.invalid:80", "connect"));
            throw new AssertionError("Network permission unexpectedly granted");
        } catch (SecurityException expected) {
            // This checks permission only; no connection is attempted.
        }
        return sum;
    }
}
