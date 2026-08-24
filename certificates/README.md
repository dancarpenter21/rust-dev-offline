# Corporate certificate authorities

Before building the `corporate` target, place the corporate root and
intermediate CA certificates in this directory. Each certificate must:

- contain only a public certificate, never a private key;
- be PEM encoded; and
- use the `.crt` filename extension.

The `corporate` build intentionally fails when no matching certificate is
present. These certificates are unavailable outside the air-gapped corporate
network, so the external `bootstrap` build does not use this directory.
