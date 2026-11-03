# WASM consumer checks

Use the pinned Zig 0.17.0 compiler and Node 22 or newer. These checks consume the
actual built module and maintained web files, without npm dependencies.

```sh
zig build wasm --summary all
node --test --test-concurrency=1 benchmark/eval/wasm/*.test.mjs
node benchmark/eval/wasm/browser.mjs benchmark/eval/outputs/wasm-browser
```

The browser runner needs an installed Chrome/Chromium executable. Set
`CHROME_BIN` when it is outside the runner's normal paths. It creates and closes
its own headless browser profile and localhost server. It does not install or
fetch tools. Chromium's `--no-sandbox` flag is confined to this disposable test
driver; run it against repository-owned staged content only.

The Node suite checks the compiled ABI, wrapper ownership, status/refusal
boundaries, legacy compatibility and independent decoded-stream controls. It
compares clean text to checked-in ground truth. Mocked host exceptions isolate
cleanup paths; they are not natural guest-trap or memory-exhaustion evidence.
Worker scheduling mocks check initialization cancellation, input snapshot timing,
timeout/reset, stale replies, disposal and pre-aborted signals. They do not
substitute for the real Worker browser checks.

The browser runner stages the same asset set as the deployment recipe, binds
hashes in `asset-manifest.json`, and drives the actual demo's file input. It
checks delayed readiness, clean text, an empty scan, nested paths, missing HTTP
assets, the real Worker heartbeat, one-job admission, cancellation and recovery.
It writes `results.json`, a screenshot and Chrome logs under its output folder.
Both suites include a wrong-text negative assertion control. This proves that
the semantic expectation fails, rather than accepting an ignored boolean.

To stage only the deployable asset set:

```sh
node benchmark/eval/wasm/stage.mjs deploy
```

These tests do not qualify other browsers, deployed GitHub Pages, aggregate host
memory, arbitrary PDF correctness or performance. Node success is separate from
the browser gate; the latter is required for the static browser consumer.
