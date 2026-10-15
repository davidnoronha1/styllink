package dev.styllink;

/** Run against a local mock server; no Android runtime needed. */
public final class LinkCheck implements Link.Listener {
    private final Link link = new Link(this);
    public void onLinkChanged() {}
    public String caps() { return "i111111"; }
    private void awaitConnected() throws Exception {
        long deadline = System.nanoTime() + 5_000_000_000L;
        while (!link.connected && System.nanoTime() < deadline) Thread.sleep(10);
        if (!link.connected) throw new AssertionError("connect failed: " + link.error);
    }
    public static void main(String[] args) throws Exception {
        LinkCheck check = new LinkCheck();
        try {
            for (int i = 0; i < 15; i++) {
                check.link.start(args[0], "test-token");
                check.awaitConnected();
            }
            // Remain connected while stale readers from previous sessions exit.
            Thread.sleep(300);
            if (!check.link.connected) throw new AssertionError("stale reader disconnected new session");
            byte[] sample = new byte[644];
            sample[4] = 42;
            check.link.sendBinary(sample, sample.length);
            sample[4] = 99; // sendBinary must copy before the caller reuses its buffer
            check.link.sendText("done");
            Thread.sleep(300);
            // The mock closes the connection; verify automatic reconnect.
            Thread.sleep(1000);
            check.awaitConnected();
            check.link.sendText("reconnected");
            Thread.sleep(200);
        } finally { check.link.stop(); }
        if (check.link.connected) throw new AssertionError("stop left connected state");
        System.out.println("Link lifecycle checks passed");
    }
}
