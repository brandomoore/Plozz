import java.io.FileOutputStream;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.lang.reflect.InvocationTargetException;
import java.nio.ByteBuffer;
import java.nio.channels.AsynchronousFileChannel;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.atomic.AtomicInteger;

/** Original bounded tests of the embedded runtime's actual native write paths. */
public final class StorageSmoke {
    private static final long LIMIT = 256L * 1024 * 1024;
    private static Class<?> budget;
    private interface Operation { void run() throws Exception; }

    private static void invoke(String method, Class<?> parameter, Object value) throws Exception {
        try {
            if (parameter == null) budget.getMethod(method).invoke(null);
            else budget.getMethod(method, parameter).invoke(null, value);
        } catch (InvocationTargetException error) {
            if (error.getCause() instanceof Exception) throw (Exception)error.getCause();
            throw error;
        }
    }

    private static void begin(long remaining) throws Exception {
        invoke("begin", null, null);
        invoke("reserve", long.class, LIMIT - remaining);
    }

    private static void denied(Operation operation) throws Exception {
        try {
            operation.run();
        } catch (IOException expected) {
            return;
        } catch (ExecutionException expected) {
            if (expected.getCause() instanceof IOException) return;
            throw expected;
        }
        throw new AssertionError("Native write exceeded its disc budget");
    }

    public static void run() throws Exception {
        budget = Class.forName("java.io.PlozzStorageBudget");
        begin(LIMIT);
        Path root = Files.createTempDirectory("plozz-storage-");
        Path source = root.resolve("source");
        Path target = root.resolve("target");
        try {
            Files.write(source, new byte[64]);
            try (FileOutputStream stream = new FileOutputStream(target.toFile())) {
                begin(1);
                stream.write(7);
                denied(() -> stream.write(8));
                if (Files.size(target) != 1) throw new AssertionError("Stream grew after rejection");
                begin(4);
                denied(() -> stream.write(new byte[8]));
            }
            try (RandomAccessFile file = new RandomAccessFile(target.toFile(), "rw")) {
                begin(4);
                denied(() -> file.seek(8));
                denied(() -> file.setLength(8));
                if (file.length() != 1) throw new AssertionError("Sparse resize bypassed budget");
                file.seek(0);
                file.write(new byte[4]);
                denied(() -> file.write(9));
            }
            try (FileOutputStream stream = new FileOutputStream(target.toFile(), true)) {
                begin(4);
                denied(() -> stream.write(new byte[8]));
            }
            try (FileChannel channel = FileChannel.open(target, StandardOpenOption.WRITE)) {
                begin(4);
                denied(() -> channel.write(ByteBuffer.allocate(8)));
                denied(() -> channel.write(ByteBuffer.allocate(1), 8));
                denied(() -> channel.write(new ByteBuffer[] {ByteBuffer.allocate(3), ByteBuffer.allocate(3)}));
                denied(() -> channel.position(8));
            }
            begin(LIMIT);
            Files.write(target, new byte[64]);
            try (FileChannel channel = FileChannel.open(target, StandardOpenOption.WRITE, StandardOpenOption.READ)) {
                begin(4);
                denied(() -> channel.map(FileChannel.MapMode.READ_WRITE, 0, 8));
                try (FileChannel input = FileChannel.open(source)) {
                    denied(() -> channel.transferFrom(input, 0, 64));
                }
            }
            try (AsynchronousFileChannel channel = AsynchronousFileChannel.open(target, StandardOpenOption.WRITE)) {
                begin(4);
                denied(() -> channel.write(ByteBuffer.allocate(8), 0).get());
            }
            java.nio.file.attribute.UserDefinedFileAttributeView attributes = Files.getFileAttributeView(
                target, java.nio.file.attribute.UserDefinedFileAttributeView.class);
            if (attributes == null) throw new AssertionError("Missing native attribute fixture path");
            begin(LIMIT);
            attributes.write("plozz-fixture", ByteBuffer.allocate(8));
            begin(4);
            denied(() -> attributes.write("plozz-fixture", ByteBuffer.allocate(8)));
            Files.delete(target);
            begin(LIMIT);
            Files.copy(source, target);
            if (Files.size(target) != 64) throw new AssertionError("Accounted copy lost data");
            Files.delete(target);
            begin(4);
            denied(() -> Files.copy(source, target));
            if (Files.exists(target) && Files.size(target) > 4)
                throw new AssertionError("Native copy bypassed budget");
            begin(LIMIT);
            AtomicInteger accepted = new AtomicInteger();
            Thread[] threads = new Thread[8];
            for (int i = 0; i < threads.length; i++) {
                threads[i] = new Thread(() -> {
                    for (;;) {
                        try {
                            invoke("reserve", long.class, 1024L * 1024);
                            accepted.incrementAndGet();
                        } catch (IOException exhausted) {
                            return;
                        } catch (Exception error) {
                            throw new AssertionError(error);
                        }
                    }
                });
                threads[i].start();
            }
            for (Thread thread : threads) thread.join(10000);
            for (Thread thread : threads) if (thread.isAlive()) throw new AssertionError("Quota worker hung");
            if (accepted.get() != 256) throw new AssertionError("Concurrent quota accounting changed");
            begin(LIMIT);
            for (int i = 0; i < 4096; i++) invoke("recordPath", String.class, "/original-fixture/" + i);
            invoke("recordPath", String.class, "/original-fixture/0");
            try {
                invoke("recordPath", String.class, "/original-fixture/4096");
                throw new AssertionError("Path budget exceeded");
            } catch (SecurityException expected) { }
            begin(LIMIT);
            denied(() -> invoke("reserve", long.class, -1L));
            denied(() -> invoke("reserve", long.class, Long.MAX_VALUE));
            begin(LIMIT);
            Files.write(target, new byte[8]);
            if (Files.size(target) != 8) throw new AssertionError("Fresh disc budget did not reset");
            System.out.println("PLOZZ_STORAGE native-stream-append-random-channel-vector-map-async-attributes-copy-concurrency-paths pass");
        } finally {
            Files.deleteIfExists(target);
            Files.deleteIfExists(source);
            Files.delete(root);
            begin(LIMIT);
        }
    }
}
