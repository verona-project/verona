# Verona bootstrap

This Verona program introduces the two package-environment variables required
by Verona:

- `VERONA_SOURCE_DIR`
- `VERONA_LIBRARY_DIR`

Build and run it from the repository root with:

```sh
make bootstrap
```

When either variable is absent, it shows the Bash `export` commands to create
them. It always prints the website and GitHub repository links.
