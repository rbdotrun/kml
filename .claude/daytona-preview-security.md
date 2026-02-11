# Daytona Preview URL Security

## Overview

Daytona sandboxes can expose HTTP services on ports 3000-9999. There are TWO ways to access these services, with VERY DIFFERENT security models.

## The Two Access Methods

### 1. Preview URL + Header Token (SECURE)

```
URL:    https://PORT-SANDBOX_ID.proxy.daytona.works
Token:  Sent via header x-daytona-preview-token
```

**How to get:**

```ruby
preview = client.get_preview_url(sandbox_id: id, port: 3000)
# preview["url"]   => "https://3000-abc123.proxy.daytona.works"
# preview["token"] => "0d8dc8657b3a36ac83434fd72136f320"
```

**How to use:**

```bash
curl -H "x-daytona-preview-token: 0d8dc8657b3a36ac83434fd72136f320" \
  https://3000-abc123.proxy.daytona.works
```

**Security properties:**

- Token is NOT in the URL
- Won't leak via: server logs, browser history, referrer headers, screenshots
- Requires explicit header - can't accidentally share access
- Works with `public: false` sandboxes

### 2. Signed Preview URL (CONVENIENT but NOT SECURE)

```
URL:    https://PORT-TOKEN.proxy.daytona.works
Token:  IS the URL itself
```

**How to get:**

```ruby
signed = client.get_signed_preview_url(sandbox_id: id, port: 3000, expires_in: 300)
# signed["url"]   => "https://3000-xyz789token.proxy.daytona.works"
# signed["token"] => "xyz789token"
```

**How to use:**

```bash
curl https://3000-xyz789token.proxy.daytona.works
# No header needed - anyone with URL has access
```

**Security WARNING:**

- Token IS the URL
- Anyone with the URL has full access
- URL leaks via: server logs, browser history, referrer headers, copy/paste, screenshots
- **BYPASSES `public: false` SETTING ENTIRELY**

## The `public` Setting

### Setting Public Status

```ruby
# When creating sandbox
client.create_sandbox(snapshot: id, public: false)  # Default: private

# Update existing sandbox
client.set_sandbox_public(sandbox_id, false)  # Make private
client.set_sandbox_public(sandbox_id, true)   # Make public
```

### What `public: false` Does

| Access Method        | public: true | public: false         |
| -------------------- | ------------ | --------------------- |
| Direct URL (no auth) | Works        | 307 redirect to OAuth |
| URL + header token   | Works        | Works                 |
| Signed URL           | Works        | **WORKS** (bypasses!) |

**CRITICAL:** Signed URLs bypass the private setting. A "private" sandbox is NOT private if you generate signed URLs.

## Testing Access

```bash
# Test 1: Direct access without auth (should fail if private)
curl -s -w "%{http_code}" https://3000-SANDBOX_ID.proxy.daytona.works
# Expected: 307 (redirect to OAuth login)

# Test 2: With header token (should work)
curl -H "x-daytona-preview-token: TOKEN" https://3000-SANDBOX_ID.proxy.daytona.works
# Expected: 200 + response body

# Test 3: Signed URL (ALWAYS works, even if private!)
curl https://3000-SIGNED_TOKEN.proxy.daytona.works
# Expected: 200 + response body (this is the security hole)
```

## Revoking Signed URLs

If a signed URL is leaked:

```ruby
# Immediately expire the token
client.expire_signed_preview_url(
  sandbox_id: id,
  port: 3000,
  token: "xyz789token"  # The token from the signed URL
)
```

After expiration:

```bash
curl https://3000-xyz789token.proxy.daytona.works
# Now returns: 307 redirect to OAuth (access revoked)
```

## Security Recommendations

### For Maximum Security

1. **Never generate signed URLs** for sensitive sandboxes
2. **Always use `public: false`** (the default)
3. **Only use header-based access** (`get_preview_url`)
4. **Rotate tokens** if you suspect compromise

### If You Must Use Signed URLs

1. Use **short expiration** (60 seconds or less)
2. **Expire immediately** after use
3. Use for **one-time access** only (webhooks, iframes)
4. **Never log** signed URLs
5. **Never share** in chat/email

### Code Patterns

**Secure pattern:**

```ruby
def secure_preview_access(sandbox_id, port)
  preview = client.get_preview_url(sandbox_id: sandbox_id, port: port)
  {
    url: preview["url"],
    headers: { "x-daytona-preview-token" => preview["token"] }
  }
end
```

**Temporary share pattern (use sparingly):**

```ruby
def temporary_share_link(sandbox_id, port, seconds: 60)
  signed = client.get_signed_preview_url(
    sandbox_id: sandbox_id,
    port: port,
    expires_in: seconds
  )

  # Schedule cleanup
  Thread.new do
    sleep(seconds)
    client.expire_signed_preview_url(
      sandbox_id: sandbox_id,
      port: port,
      token: signed["token"]
    )
  end

  signed["url"]
end
```

## API Reference

### get_preview_url (SECURE)

```
GET /sandbox/{id}/ports/{port}/preview-url

Response:
{
  "sandboxId": "abc123",
  "url": "https://3000-abc123.proxy.daytona.works",
  "token": "0d8dc8657b3a36ac83434fd72136f320"
}
```

### get_signed_preview_url (CONVENIENT)

```
GET /sandbox/{id}/ports/{port}/signed-preview-url?expiresInSeconds=300

Response:
{
  "sandboxId": "abc123",
  "port": 3000,
  "token": "xyz789token",
  "url": "https://3000-xyz789token.proxy.daytona.works"
}
```

### expire_signed_preview_url

```
POST /sandbox/{id}/ports/{port}/signed-preview-url/{token}/expire

Response: 200 OK (empty body)
```

### set_sandbox_public

```
POST /sandbox/{id}/public/{true|false}

Response: Updated sandbox object
```

## Summary

| Feature                  | Header Token       | Signed URL        |
| ------------------------ | ------------------ | ----------------- |
| Security                 | HIGH               | LOW               |
| Token location           | HTTP header        | URL itself        |
| Leak risk                | Low                | High              |
| Respects `public: false` | Yes                | **NO**            |
| Can be revoked           | No (use new token) | Yes               |
| Use case                 | API access         | Iframes, webhooks |
| Recommendation           | **USE THIS**       | Avoid if possible |
