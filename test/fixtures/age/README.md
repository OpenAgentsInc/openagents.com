# age reference fixture

`reference.age` was produced by the reference `age` implementation (v1.3.1):

```sh
printf 'openagents account export fixture\n' > plain.txt
age --encrypt -r age1ja3nzz0wlmuqvsfhrx7w4kq00knnmu3ur32y47734k5javp4cqnqumg72a \
  -o reference.age plain.txt
```

`test/openagents/data_rights/age_test.exs` decrypts it with
`OpenAgents.Test.AgeDocument`, the decryptor written from the specification.
That direction is what pins our reading of the format to the reference
implementation, so the encryption round trip means something where the `age`
binary is not installed.

The identity is a throwaway generated for this fixture and protects nothing.
It lives in the test as `@fixture_secret` rather than in a file, so nothing
here looks like a credential in use.
