# Contract: Remote Self-Test

```bash
open -n "$HOME/Applications/Category Recommender.app" --args --self-test-remote --out /tmp/catrec-remote.json
```

Checks the connection to the configured recommender with fabricated data. Changes nothing: it creates no category set and sends no feedback, so nothing is learned. The suggestion it asks for expires on the service by itself. Design: [research R9](../research.md#r9-the-remote-self-test).

## Output

One JSON object, written to `--out` (or stdout), then the app exits with status 0.

```json
{
  "ok": false,
  "steps": [
    { "name": "address", "result": "pass" },
    { "name": "reachable", "result": "pass" },
    { "name": "identity", "result": "pass" },
    { "name": "accepted", "result": "fail", "hint": "The recommender does not accept this Mac. Add this device's fingerprint to access.devices." },
    { "name": "model", "result": "not_run" },
    { "name": "timing", "result": "not_run" }
  ]
}
```

| Step | Passes when | Hint on failure |
|------|-------------|-----------------|
| `address` | `Destination.check` accepts the base URL, and a name resolves to allowed addresses only | The address is not on this Mac or the home network |
| `reachable` | A TCP connection opens within 5 s | Is the Mac mini awake and on this network? Is Local Network allowed for the app? |
| `identity` | The server's certificate chains to the configured CA and names the host | The recommender's certificate is not from your CA, or does not name this address |
| `accepted` | `GET /v1/health` with the device certificate answers 200 | Not installed: import this Mac's .p12. Refused: add this device's fingerprint to access.devices |
| `model` | Health says `status: ok` | The model on the recommender is not ready yet |
| `timing` | `POST /v1/suggestions` with a fabricated email and fabricated `categories` answers 200 | The recommender did not answer in time |

When `timing` ran, the object also has `"timingMs": <integer>`.

The output never contains the address, a certificate field, the fabricated email or its labels. `ok` is true only when all six steps pass. After a failure, the later steps are `not_run`.

In local mode (no CA configured), the self-test reports `address` as fail with the hint "This app is set up for the service on this Mac", and the other steps as `not_run`.
