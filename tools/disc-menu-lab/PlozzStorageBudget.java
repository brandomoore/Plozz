package java.io;

import java.util.HashSet;
import java.util.Set;

/**
 * Application-owned accounting for the embedded disc runtime, not a filesystem sandbox.
 * @hidden
 */
public final class PlozzStorageBudget {
    private static final long BYTE_LIMIT = 256L * 1024 * 1024;
    private static final int PATH_LIMIT = 4096;
    private static final Set<String> paths = new HashSet<String>();
    private static long remaining;
    private static boolean active;
    private static boolean reported;

    private PlozzStorageBudget() { }

    /** Reset only between fully terminated discs, while no disc policy is installed. */
    @SuppressWarnings("removal")
    public static synchronized void begin() {
        if (System.getSecurityManager() != null) {
            throw new SecurityException("An active disc cannot reset storage accounting");
        }
        paths.clear();
        remaining = BYTE_LIMIT;
        reported = false;
        active = true;
    }

    /**
     * Query whether the native copy fast paths must use the accounted fallback.
     * @return whether native writes require accounting
     */
    public static synchronized boolean isActive() {
        return active;
    }

    /**
     * Reserve before a native operation; failed/partial writes do not refund the budget.
     * @param bytes maximum bytes or writable position covered by the operation
     * @throws IOException if the session cannot admit the operation
     */
    public static synchronized void reserve(long bytes) throws IOException {
        if (!active) return;
        if (bytes < 0 || bytes > remaining) {
            report();
            throw new IOException("Disc storage byte budget exceeded");
        }
        remaining -= bytes;
    }

    /**
     * Bound distinct write destinations, including directories.
     * @param canonicalPath destination after the disc's path authorization check
     */
    public static synchronized void recordPath(String canonicalPath) {
        if (!active || paths.contains(canonicalPath)) return;
        if (paths.size() >= PATH_LIMIT) {
            report();
            throw new SecurityException("Disc storage path budget exceeded");
        }
        paths.add(canonicalPath);
    }

    private static void report() {
        if (!reported) {
            reported = true;
            System.err.println("PLOZZ_BDJ disc storage budget exceeded");
        }
    }
}
