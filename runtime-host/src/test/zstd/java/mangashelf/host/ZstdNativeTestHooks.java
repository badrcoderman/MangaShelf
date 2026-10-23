package mangashelf.host;

/** These symbols exist only in authored test libraries, never the iOS archive. */
public final class ZstdNativeTestHooks {
    private ZstdNativeTestHooks() { }
    public static native void faultNext(int stage);
    public static native int activeContexts();
    public static native int globalReferences();
    public static native int loadKind();
    public static native int shutdown();
    public static native void armGate();
    public static native boolean gateEntered();
    public static native void releaseGate();
}
