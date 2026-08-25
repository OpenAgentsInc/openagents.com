# Ox Alpha on OpenCode

Date: 2026-08-25

Status: Measured

You can reach the Ox Alpha model through OpenCode on two different endpoints:
OpenCode Zen and OpenCode Go. The Zen version is unauthenticated and free.
The Go version requires an OpenCode Go API key.

## OpenCode Zen (unauthenticated)

OpenCode serves a free preview of Ox Alpha through its Zen gateway. You do not
need an account or an API key.

The model ID is `x-preview-f-free` and the endpoint is:

```
POST https://opencode.ai/zen/v1/chat/completions
```

Example request:

```sh
curl -s -X POST https://opencode.ai/zen/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "x-preview-f-free",
    "messages": [
      {"role": "user", "content": "hi"}
    ],
    "stream": false
  }'
```

The public models list at `https://opencode.ai/zen/v1/models` also includes
`x-preview-f-free`. A measured response returned `cost: "0"`, so this is the
cheapest way to try Ox Alpha when it is available.

Note that the model is a limited-time free preview. It is rate-limited by source
IP and may become unavailable or change identifiers without notice.

## OpenCode Go (authenticated)

The same model is also listed in OpenCode Go as `ox-alpha-free`. This version
requires an OpenCode Go subscription and a workspace API key.

The model ID is `ox-alpha-free` and the endpoint is:

```
POST https://opencode.ai/zen/go/v1/chat/completions
```

Example request:

```sh
curl -s -X POST https://opencode.ai/zen/go/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer $OPENCODE_GO_API_KEY' \
  -d '{
    "model": "ox-alpha-free",
    "messages": [
      {"role": "user", "content": "hi"}
    ],
    "stream": false
  }'
```

The Go gateway parses the `Authorization` header as a `Bearer` token and looks
up the key in the OpenCode console database. A missing, invalid, or exhausted
key returns `401`.

## The `public` API key marker

The OpenCode CLI provider in `packages/opencode/src/provider/provider.ts` sets
`apiKey: "public"` when it does not find a stored credential. This is not a real
key. The OpenCode gateway explicitly ignores the string `public` and treats the
request as unauthenticated. If the model does not allow anonymous access, the
gateway returns `401 Missing API key`.

## Verification

The measurements in this document were made on 2026-08-25:

- `GET https://opencode.ai/zen/v1/models` returned `x-preview-f-free` without
  authentication.
- `POST https://opencode.ai/zen/v1/chat/completions` with `x-preview-f-free`
  returned a `200` completion with `cost: "0"` and no `Authorization` header.
- `POST https://opencode.ai/zen/go/v1/chat/completions` with `ox-alpha-free`
  returned `401 Missing API key`.

Recheck the live endpoints before relying on these values in production.
