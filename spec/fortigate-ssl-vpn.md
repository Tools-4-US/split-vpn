# FortiGate SSL-VPN: how Geleit connects

Notes shared by every Geleit client. They describe what the gateway expects, independent of platform.

## Tunnel

Clients delegate the tunnel itself to [openfortivpn](https://github.com/adrienverge/openfortivpn) (PPP over TLS). Geleit always starts it with `set-dns = 0` and `pppd-use-peerdns = 0`, and with `set-routes = 0` in split mode, then applies routes and DNS itself once the tunnel is up.

Lines in openfortivpn's output that clients rely on:

| Line | Meaning |
|---|---|
| `Got addresses: [<ip>], ns [<dns1>, <dns2>]` | Address assigned to the client and the gateway's DNS servers |
| `Interface <ifname> is UP` | Tunnel interface (e.g. `ppp0`); may be garbled by interleaved pppd output, so clients must fall back to discovering the interface |
| `Tunnel is up and running` | Safe to apply routes and DNS |

## SSO (SAML)

1. The client listens on `http://127.0.0.1:<port>` (default `8020`).
2. It opens `https://<gateway>:<port>/remote/saml/start?redirect=1` (plus `&realm=<realm>` when set) in the user's browser.
3. After the identity provider login, the gateway redirects the browser to `http://127.0.0.1:<port>/?id=<session-id>`.
4. The client exchanges the id for a session cookie with a request that **must mirror openfortivpn's own**:

   ```http
   GET /remote/saml/auth_id?id=<session-id> HTTP/1.1
   Host: <gateway>:<port>
   User-Agent: Mozilla/5.0 SV1
   Accept: */*
   Accept-Encoding: identity
   Pragma: no-cache
   Cache-Control: no-store, no-cache, must-revalidate
   If-Modified-Since: Sat, 1 Jan 2000 00:00:00 GMT
   Content-Type: application/x-www-form-urlencoded
   Cookie:
   Content-Length: 0
   ```

   Lessons learned on a real gateway:

   - Use plain HTTP/1.1 (ALPN `http/1.1`). A cookie obtained through a generic HTTP stack (HTTP/2, different user agent) was rejected later, when the tunnel fetched `/remote/fortisslvpn_xml`.
   - The gateway always sends a **clearing** `Set-Cookie: SVPNCOOKIE=; expires=…1984…` alongside the real one. Read each `Set-Cookie` header separately and take the first **non-empty** `SVPNCOOKIE`. Never merge headers.
   - On success the gateway keeps the connection open even with `Connection: close`. Stop reading after the end of the headers (`\r\n\r\n`); do not wait for EOF.

5. The cookie (`SVPNCOOKIE=<value>`) is handed to `openfortivpn --cookie-on-stdin`. openfortivpn does not validate it during "Authenticated"; an invalid cookie only shows up as `Could not get VPN configuration`.

## Reconnection

After a drop, clients retry with exponential backoff starting at 5 s, for a total window of 10 minutes.

- Before each attempt, probe TCP reachability of the gateway; if it is unreachable, skip the attempt (and never open the browser).
- **openfortivpn always logs out on exit** (`Logged out.`), which invalidates the SSO cookie on the gateway. The cookie only survives when the logout itself fails (`Could not log out.`), typically after a real network outage.
- Therefore: if the previous tunnel logged out, or a retry fails with `Could not get VPN configuration`, discard the cookie and run the SSO flow again on the next attempt. With an active identity provider session this completes without user interaction in a few seconds; use a shorter timeout (90 s) than the first login.
