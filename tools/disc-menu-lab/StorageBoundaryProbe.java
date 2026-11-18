package org.plozz.disclab;

/** Original production-path permission probes, without writing outside the disc. */
public final class StorageBoundaryProbe {
    public static void run(SecurityManager security) {
        for (String property : new String[] {"dvb.persistent.root", "bluray.bindingunit.root"}) {
            String root = System.getProperty(property);
            if (root == null) throw new IllegalStateException("Missing disc storage root");
            while (root.endsWith(java.io.File.separator)) root = root.substring(0, root.length() - 1);
            security.checkWrite(root);
            security.checkWrite(root + "/original-fixture");
            try {
                security.checkWrite(root + "-sibling/original-fixture");
                throw new IllegalStateException("Disc policy allowed a sibling storage root");
            } catch (SecurityException expected) { }
        }
        try {
            Class.forName("java.io.PlozzStorageBudget").getMethod("begin").invoke(null);
            throw new IllegalStateException("Disc code reset its storage accounting");
        } catch (java.lang.reflect.InvocationTargetException expected) {
            if (!(expected.getCause() instanceof SecurityException))
                throw new IllegalStateException("Unexpected storage reset failure", expected);
        } catch (ReflectiveOperationException error) {
            throw new IllegalStateException("Storage accounting is unavailable", error);
        }
        System.out.println("PLOZZ_XLET storage-root-boundaries-and-reset-denied");
    }
}
