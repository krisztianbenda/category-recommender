# Contract: Category Recommender HTTP API (v1)

- **Transport**: HTTPS with mutual TLS (research R13). A request without an allow-listed client certificate is rejected during the TLS handshake or with `403`.
- **Base path**: `/v1`
- **Format**: `application/json; charset=utf-8`
- **Errors**: `{ "error": { "code": "<string>", "message": "<human text>" } }`. Error messages never echo email content.

Common error codes: `invalid_request` (400), `forbidden` (403), `not_found` (404), `suggestion_expired` (410), `content_mismatch` (409), `llm_unavailable` (503, retry later; never forwarded to another service).

## Types

```ts
type CategoryPath = string;            // "Family" or "Family/Baby"; max 2 levels, case-insensitive

interface Email {
  from: string;                        // sender display + address
  to?: string[];
  subject: string;
  body: string;                        // plain text
}

interface RankedCategory {
  path: CategoryPath;
  score: number;                       // 0..1, relative within this response
}

interface Suggestion {
  suggestionId: string;
  category: CategoryPath;              // the one suggested category (existing or proposed)
  isNew: boolean;                      // true → category is a proposal, not yet created
  newCategory?: { parent: CategoryPath | null; name: string };   // present iff isNew
  confidence: "high" | "medium" | "low";
  reason: string;                      // ≤ 25 words
  runnersUp: RankedCategory[];         // existing categories only, best first, max 5
  similarPastDecisions: number;        // how many learning examples informed this
  truncated: boolean;                  // email was shortened before processing
  expiresAt: string;                   // ISO-8601; feedback must arrive before this
}
```

## Endpoints

### `POST /v1/suggestions`: get a suggestion (US1)

Request (exactly one of `categories` or `categorySetId`):

```json
{
  "email": { "from": "Dad <dad@example.test>", "subject": "Sunday lunch", "body": "..." },
  "categories": ["Family", "Family/Baby", "Gadgets", "Travelling/TripXYZ"]
}
```

```json
{ "email": { "...": "..." }, "categorySetId": "01J..." }
```

`200` → `Suggestion`. `400` if: no email text, a path deeper than 2, both or neither category source given, or an empty category list *and* no default set. An empty category list with a default set is allowed: the system may then only propose a new top-level category.

### `POST /v1/suggestions/{suggestionId}/feedback`: confirm or correct (US2)

```json
{
  "email": { "...": "same email as in the suggestion request" },
  "decision": "confirm"
}
```

```json
{ "email": { "...": "..." }, "decision": "choose", "category": "Finance" }
```

```json
{ "email": { "...": "..." }, "decision": "accept_new", "newCategory": { "parent": "Travelling", "name": "Trip Lisbon 2027" } }
```

- `confirm`: accepts `category`. If that was a new proposal, this is the same as `accept_new` with the proposed name.
- `choose`: `category` must be one of the original candidates.
- `accept_new`: creates the category (the name may be edited; depth and duplicate rules apply).

`201` → `{ "learningExampleId": "...", "categoryId": "..." }`. `409 content_mismatch` if the email hash differs. `410 suggestion_expired` after the TTL or a restart. A second feedback on the same suggestion returns `409`.

### Category sets (US3)

| Method & path | Body | Result |
|---------------|------|--------|
| `GET /v1/category-sets` | | `[{ id, name, isDefault, categoryCount }]` |
| `POST /v1/category-sets` | `{ name, categories?: CategoryPath[] }` | `201 { id }` |
| `GET /v1/category-sets/{id}` | | `{ id, name, isDefault, categories: [{ id, path, parentId, exampleCount }] }` |
| `PATCH /v1/category-sets/{id}` | `{ name }` | `200` |
| `DELETE /v1/category-sets/{id}` | | `204` (deletes its categories and examples; the default set cannot be deleted) |
| `POST /v1/category-sets/{id}/categories` | `{ path }` | `201 { id }`; `400` if depth > 2 or duplicate |
| `PATCH /v1/categories/{id}` | `{ name?, parentId?: string \| null }` | `200`; examples are preserved |
| `DELETE /v1/categories/{id}?cascade=true` | | `204`; without `cascade`, `409` if it has children |

### Learned data (US4)

| Method & path | Result |
|---------------|--------|
| `GET /v1/learning-examples?categoryId=&limit=&cursor=` | `{ items: [{ id, categoryPath, sender, subject, snippet, outcome, decidedAt }], nextCursor }` |
| `DELETE /v1/learning-examples/{id}` | `204` |
| `DELETE /v1/categories/{id}/learning-examples` | `204` |
| `DELETE /v1/me/data` with body `{ "confirm": "DELETE ALL" }` | `204`: removes all sets, categories, examples and decisions for the user |

### Accuracy (FR-020)

`GET /v1/stats/accuracy?window=50|100` →

```json
{ "window": 100, "decisions": 100, "acceptedWithoutCorrection": 0.87,
  "byConfidence": { "high": 0.96, "medium": 0.78, "low": 0.41 },
  "newProposals": { "made": 6, "accepted": 4 } }
```

### Health

`GET /v1/health` → `{ "status": "ok" | "degraded", "llm": "up" | "down", "embeddings": "up" | "down" }`. Contains no data.

## Versioning

Breaking changes create `/v2`. Additive fields may be added to v1 responses; clients must ignore unknown fields.
