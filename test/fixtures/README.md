# HTTPS callback fixtures

These files are public test credentials for `callback.test`. Never use the key
outside tests. The private certificate authority is trusted only through
`JULIA_SSL_CA_ROOTS_PATH` inside the test; it is not installed in a keychain.

The RSA-2048 / SHA-256 leaf certificate has a DNS subject alternative name and
the server-authentication extended key usage. Its test validity spans
2018-01-01 through 2040-01-01 so the fixture also works with macOS
SecureTransport's rules for certificates issued before July 2019.

The tests require a successful hostname check for `callback.test` and a failed
check for `wrong.test` while connecting to the same pinned loopback address.
